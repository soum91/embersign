// SPDX-License-Identifier: MIT
//! Device-initiated remote pairing on iOS 27.
//! Uses the MIT-licensed idevice PairableHost implementation. No pairing
//! material is logged, transmitted off-device, or persisted by this library.

use std::ffi::{CStr, CString, c_char, c_void};
use std::net::{Ipv4Addr, TcpListener};
use std::ptr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use tokio::sync::Notify;
use tokio::task::JoinSet;

type PINCallback = Option<extern "C" fn(*const c_char, *mut c_void)>;

pub struct EmberPairingSession {
    port: u16,
    name: CString,
    records: Vec<(CString, CString)>,
    socket: Mutex<Option<TcpListener>>,
    identity: Mutex<Option<(RpPairingFile, PairableHostInfo)>>,
    stop: Notify,
    stopped: AtomicBool,
}

fn failure(target: *mut *mut c_char, message: &str) {
    if !target.is_null() {
        unsafe {
            *target = CString::new(message)
                .unwrap_or_else(|_| c"Pairing failed".to_owned())
                .into_raw();
        }
    }
}

/// # Safety
/// The caller passes a non-null, NUL-terminated name and a writable error pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_start(
    host_name: *const c_char,
    error: *mut *mut c_char,
) -> *mut EmberPairingSession {
    if host_name.is_null() {
        failure(error, "Pairing host name is missing.");
        return ptr::null_mut();
    }
    let Ok(label) = (unsafe { CStr::from_ptr(host_name) }).to_str() else {
        failure(error, "Pairing host name is not valid UTF-8.");
        return ptr::null_mut();
    };
    if label.is_empty() || label.len() > 48 {
        failure(error, "Pairing host name must have 1 to 48 characters.");
        return ptr::null_mut();
    }

    let Ok(listener) = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0)) else {
        failure(error, "Cannot listen for pairing. Allow EmberSign to use the local network.");
        return ptr::null_mut();
    };
    let Ok(addr) = listener.local_addr() else {
        failure(error, "Cannot determine the pairing port.");
        return ptr::null_mut();
    };
    if listener.set_nonblocking(true).is_err() {
        failure(error, "Cannot configure the local pairing socket.");
        return ptr::null_mut();
    }

    // A new host key is required when the phone has forgotten or replaced
    // its previous trust record. The name-derived identifier remains stable.
    let file = RpPairingFile::generate(label);
    let host = PairableHostInfo::generate(label, "Mac17,7");
    let records = host.mdns_txt_records(&file.identifier).into_iter()
        .filter_map(|(key, value)| Some((CString::new(key).ok()?, CString::new(value).ok()?)))
        .collect();
    let session = EmberPairingSession {
        port: addr.port(),
        name: CString::new(file.identifier.clone()).unwrap_or_default(),
        records,
        socket: Mutex::new(Some(listener)),
        identity: Mutex::new(Some((file, host))),
        stop: Notify::new(),
        stopped: AtomicBool::new(false),
    };
    Box::into_raw(Box::new(session))
}

/// # Safety
/// The pointer must originate from embersign_pair_start and still be alive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_port(s: *const EmberPairingSession) -> u16 {
    unsafe { &*s }.port
}
/// # Safety
/// The pointer must originate from embersign_pair_start and still be alive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_service_name(s: *const EmberPairingSession) -> *const c_char {
    unsafe { &*s }.name.as_ptr()
}
/// # Safety
/// The pointer must originate from embersign_pair_start and still be alive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_txt_count(s: *const EmberPairingSession) -> usize {
    unsafe { &*s }.records.len()
}
/// # Safety
/// The pointer must originate from embersign_pair_start and still be alive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_txt_key(s: *const EmberPairingSession, i: usize) -> *const c_char {
    unsafe { &*s }.records.get(i).map_or(ptr::null(), |entry| entry.0.as_ptr())
}
/// # Safety
/// The pointer must originate from embersign_pair_start and still be alive.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_txt_value(s: *const EmberPairingSession, i: usize) -> *const c_char {
    unsafe { &*s }.records.get(i).map_or(ptr::null(), |entry| entry.1.as_ptr())
}

#[derive(Clone, Copy)]
struct Notification {
    callback: PINCallback,
    context: *mut c_void,
}
unsafe impl Send for Notification {}
unsafe impl Sync for Notification {}
impl Notification {
    fn emit(self, value: &str) {
        if let (Some(callback), Ok(pin)) = (self.callback, CString::new(value)) {
            callback(pin.as_ptr(), self.context);
        }
    }
}

async fn await_pairing(
    session: &EmberPairingSession,
    listener: TcpListener,
    file: RpPairingFile,
    info: PairableHostInfo,
    notification: Notification,
) -> Result<(RpPairingFile, String), String> {
    let socket = tokio::net::TcpListener::from_std(listener)
        .map_err(|error| format!("Could not open pairing listener: {error}"))?;
    let pin_issued = Arc::new(AtomicBool::new(false));
    let mut connections = JoinSet::new();
    let discover = async {
        loop {
            tokio::select! {
                incoming = socket.accept() => {
                    let (stream, _) = incoming.map_err(|error| format!("Network pairing failed: {error}"))?;
                    let mut credentials = file.clone();
                    let device = info.clone();
                    let shown = Arc::clone(&pin_issued);
                    connections.spawn(async move {
                        let mut peer = PairableHost::new(RpPairingSocket::new_device(stream), device);
                        let result = peer.accept(&mut credentials, |pin| {
                            shown.store(true, Ordering::SeqCst);
                            notification.emit(&pin);
                            async {}
                        }).await;
                        result.map(|peer| (credentials, peer.name)).map_err(|e| e.to_string())
                    });
                }
                completed = connections.join_next(), if !connections.is_empty() => {
                    match completed {
                        Some(Ok(Ok(record))) => return Ok(record),
                        Some(Ok(Err(reason))) if pin_issued.load(Ordering::SeqCst) => return Err(reason),
                        Some(Err(error)) if pin_issued.load(Ordering::SeqCst) => return Err(error.to_string()),
                        _ => {}
                    }
                }
            }
        }
    };
    if session.stopped.load(Ordering::SeqCst) { return Err("Cancelled".into()); }
    tokio::select! {
        biased;
        _ = session.stop.notified() => Err("Cancelled".into()),
        outcome = discover => outcome,
    }
}

/// # Safety
/// Session is valid and all non-null out-pointers are writable. Call once per
/// session, on a worker thread. Destroy the session only after this returns.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_wait(
    s: *const EmberPairingSession,
    on_pin: PINCallback,
    context: *mut c_void,
    pairing_bytes: *mut *mut u8,
    pairing_length: *mut usize,
    device_name: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    let session = unsafe { &*s };
    let listener = session.socket.lock().ok().and_then(|mut socket| socket.take());
    let identity = session.identity.lock().ok().and_then(|mut value| value.take());
    let (Some(listener), Some((file, info))) = (listener, identity) else {
        failure(error, "Pairing is already running or has finished.");
        return 1;
    };
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        failure(error, "Unable to start the pairing network runtime.");
        return 1;
    };
    let outcome = runtime.block_on(await_pairing(
        session, listener, file, info, Notification { callback: on_pin, context },
    ));
    match outcome {
        Ok((record, name)) => {
            let bytes = record.to_bytes().into_boxed_slice();
            if !pairing_length.is_null() { unsafe { *pairing_length = bytes.len() }; }
            if !pairing_bytes.is_null() { unsafe { *pairing_bytes = Box::into_raw(bytes) as *mut u8 }; }
            if !device_name.is_null() {
                unsafe { *device_name = CString::new(name).unwrap_or_default().into_raw() };
            }
            0
        }
        Err(message) if message == "Cancelled" => 2,
        Err(message) => {
            failure(error, &message);
            1
        }
    }
}

/// # Safety
/// The session pointer remains alive until the waiting thread has returned.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_cancel(s: *const EmberPairingSession) {
    let session = unsafe { &*s };
    session.stopped.store(true, Ordering::SeqCst);
    session.stop.notify_one();
}
/// # Safety
/// All pairing workers have returned and s was created by embersign_pair_start.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_destroy(s: *mut EmberPairingSession) {
    if !s.is_null() { drop(unsafe { Box::from_raw(s) }); }
}
/// # Safety
/// Pointer and length were provided by embersign_pair_wait.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_free_bytes(bytes: *mut u8, len: usize) {
    if !bytes.is_null() { drop(unsafe { Box::from_raw(ptr::slice_from_raw_parts_mut(bytes, len)) }); }
}
/// # Safety
/// Pointer was provided by an EmberSign pairing API.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_pair_free_string(value: *mut c_char) {
    if !value.is_null() { drop(unsafe { CString::from_raw(value) }); }
}
