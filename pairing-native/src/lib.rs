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

// Watch installation uses the same *local* remote-pairing credentials as JIT.
// The pairing key and any Watch provisioning credentials never leave the phone.
// This deliberately does NOT uninstall an existing Watch app: a failed update
// must not delete a working installation or its data.

use idevice::Idevice;
use idevice::remote_pairing::{RemotePairingClient, connect_tls_psk_tunnel_native};
use idevice::rsd::RsdHandshake;
use idevice::services::{companion_proxy::CompanionProxy, lockdown::LockdownClient};
use idevice::tcp::{adapter::Adapter, handle::AdapterHandle};
use plist::{Dictionary, Value};
use std::fs;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};

const WATCH_LOCKDOWN_PORT: u16 = 62078;
const WATCH_LOCKDOWN_NAME: &str = "com.apple.mobile.lockdownd";
const WATCH_ZIP_NAME: &str = "com.apple.streaming_zip_conduit";
const WATCH_ZIP_END: &[u8] = &[0x50, 0x4b, 0x01, 0x02];
const WATCH_ZIP_EXTRA: &[u8] = &[
    0x55, 0x54, 0x0d, 0x00, 0x07, 0xf3, 0xa2, 0xec, 0x60, 0xf6, 0xa2, 0xec, 0x60,
    0xf3, 0xa2, 0xec, 0x60, 0x75, 0x78, 0x0b, 0x00, 0x01, 0x04, 0xf5, 0x01, 0x00,
    0x00, 0x04, 0x14, 0x00, 0x00, 0x00,
];

fn watch_arg(pointer: *const c_char, name: &str) -> Result<String, String> {
    if pointer.is_null() { return Err(format!("Missing {name}.")); }
    let value = unsafe { CStr::from_ptr(pointer) }
        .to_str().map_err(|_| format!("Invalid UTF-8 in {name}."))?;
    if value.is_empty() || value.len() > 4096 {
        return Err(format!("Invalid length for {name}."));
    }
    Ok(value.to_owned())
}

async fn watch_tunnel(
    pairing_path: &str, device_ip: &str, port: u16,
) -> Result<(AdapterHandle, RsdHandshake), String> {
    let data = fs::read(pairing_path).map_err(|e| format!("Read remote pairing: {e}"))?;
    if data.len() > 4 * 1024 * 1024 { return Err("Pairing record is too large.".into()); }
    let mut pairing = RpPairingFile::from_bytes(&data).map_err(|e| e.to_string())?;
    let addr: SocketAddr = format!("{device_ip}:{port}").parse()
        .map_err(|_| "Enter the IPv4 Device IP and port from LocalDevVPN.".to_string())?;
    let stream = tokio::time::timeout(std::time::Duration::from_secs(15),
        tokio::net::TcpStream::connect(addr))
        .await.map_err(|_| "Remote pairing connection timed out.".to_string())?
        .map_err(|e| format!("Remote pairing connection: {e}"))?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), "EmberSign");
    // A previously approved remote pairing should verify immediately. If the
    // device has forgotten it, a re-pair attempt cannot pass without an actual
    // user-approved PIN; we do not invent or persist one.
    rpc.connect(&mut pairing, || async { String::new() }).await
        .map_err(|e| format!("Remote pairing verification failed. Re-pair in EmberSign: {e}"))?;
    let tunnel_port = rpc.create_tcp_listener().await.map_err(|e| e.to_string())?;
    let tunnel_addr = SocketAddr::new(addr.ip(), tunnel_port);
    let tcp = tokio::net::TcpStream::connect(tunnel_addr)
        .await.map_err(|e| format!("Open paired tunnel: {e}"))?;
    let tunnel = connect_tls_psk_tunnel_native(tcp, rpc.encryption_key())
        .await.map_err(|e| format!("Secure tunnel: {e}"))?;
    let client_ip: IpAddr = tunnel.info.client_address.parse()
        .map_err(|_| "Invalid client address in tunnel response".to_string())?;
    let server_ip: IpAddr = tunnel.info.server_address.parse()
        .map_err(|_| "Invalid device address in tunnel response".to_string())?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;
    let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client_ip, server_ip);
    adapter.set_mss(mtu.clamp(128, 8192) - 60);
    let mut adapter = adapter.to_async_handle();
    let rsd = adapter.connect(rsd_port).await
        .map_err(|e| format!("Remote service discovery: {e}"))?;
    let handshake = RsdHandshake::new(rsd).await.map_err(|e| e.to_string())?;
    Ok((adapter, handshake))
}

async fn watch_registry(
    adapter: &mut AdapterHandle, handshake: &mut RsdHandshake,
) -> Result<Vec<String>, String> {
    let mut proxy = handshake.connect::<CompanionProxy>(adapter)
        .await.map_err(|e| format!("Watch companion proxy: {e}"))?;
    proxy.get_device_registry().await.map_err(|e| format!("Paired Watches: {e}"))
}

fn progress(notification: Notification, message: &str) { notification.emit(message); }

/// # Safety
/// C strings are NUL-terminated; output/error pointers are writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_watch_discover(
    pairing_path: *const c_char, device_ip: *const c_char, device_port: u16,
    iphone_udid: *mut *mut c_char, watch_udids: *mut *mut c_char,
    error: *mut *mut c_char,
) -> i32 {
    if device_port == 0 || iphone_udid.is_null() || watch_udids.is_null() {
        failure(error, "Invalid Watch discovery arguments."); return 1;
    }
    let outcome = (|| -> Result<(String, String), String> {
        let pairing_path = watch_arg(pairing_path, "pairing path")?;
        let device_ip = watch_arg(device_ip, "Device IP")?;
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
            .map_err(|e| e.to_string())?;
        let (phone, watches) = runtime.block_on(async {
            let (mut adapter, mut handshake) = watch_tunnel(&pairing_path, &device_ip, device_port).await?;
            let mut lockdown = handshake.connect::<LockdownClient>(&mut adapter).await
                .map_err(|e| format!("iPhone lockdown: {e}"))?;
            let phone = lockdown.get_value(Some("UniqueDeviceID"), None).await
                .map_err(|e| format!("Read iPhone UDID: {e}"))?
                .into_string().ok_or("iPhone did not return its UDID")?;
            let watches = watch_registry(&mut adapter, &mut handshake).await?;
            Ok::<_, String>((phone, watches))
        })?;
        Ok((phone, watches.join(",")))
    })();
    match outcome {
        Ok((phone, csv)) => {
            unsafe { *iphone_udid = CString::new(phone).unwrap_or_default().into_raw(); }
            unsafe { *watch_udids = CString::new(csv).unwrap_or_default().into_raw(); }
            0
        }
        Err(message) => { failure(error, &message); 1 }
    }
}

async fn watch_install(
    pairing_path: &str, device_ip: &str, device_port: u16,
    host_id: &str, system_buid: &str, watch_app: &Path, notice: Notification,
) -> Result<(), String> {
    progress(notice, "Connecting to paired iPhone…");
    let (mut adapter, mut handshake) = watch_tunnel(pairing_path, device_ip, device_port).await?;
    let watches = watch_registry(&mut adapter, &mut handshake).await?;
    if watches.is_empty() { return Err("No paired Apple Watch was found. Keep it unlocked and near your iPhone.".into()); }
    if watches.len() != 1 {
        return Err("More than one Watch was found. Select one in a future update; no installation was attempted.".into());
    }
    progress(notice, "Forwarding Apple Watch services…");
    let forwarded_lockdown = {
        let mut proxy = handshake.connect::<CompanionProxy>(&mut adapter)
            .await.map_err(|e| e.to_string())?;
        proxy.start_forwarding_service_port(WATCH_LOCKDOWN_PORT, Some(WATCH_LOCKDOWN_NAME), None)
            .await.map_err(|e| format!("Watch lockdown forwarding: {e}"))?
    };
    let lockdown_stream = adapter.connect(forwarded_lockdown).await
        .map_err(|e| format!("Connect to Watch lockdown: {e}"))?;
    let mut lockdown = LockdownClient::new(Idevice::new(Box::new(lockdown_stream), "EmberSign"));
    progress(notice, "Pairing with Apple Watch…");
    let watch_pairing = lockdown.pair(host_id, system_buid, Some("EmberSign"))
        .await.map_err(|e| format!("Watch pairing: {e}"))?;
    let legacy = lockdown.start_session(&watch_pairing)
        .await.map_err(|e| format!("Watch lockdown session: {e}"))?;
    let (remote_port, ssl) = lockdown.start_service(WATCH_ZIP_NAME)
        .await.map_err(|e| format!("Watch zip service unavailable: {e}"))?;
    let forwarded_zip = {
        let mut proxy = handshake.connect::<CompanionProxy>(&mut adapter)
            .await.map_err(|e| e.to_string())?;
        proxy.start_forwarding_service_port(remote_port, Some(WATCH_ZIP_NAME), None)
            .await.map_err(|e| format!("Watch zip forwarding: {e}"))?
    };
    let zip_stream = adapter.connect(forwarded_zip).await
        .map_err(|e| format!("Connect to Watch zip service: {e}"))?;
    let mut conn = Idevice::new(Box::new(zip_stream), "EmberSign");
    if ssl { conn.start_session(&watch_pairing, legacy).await
        .map_err(|e| format!("Secure Watch zip session: {e}"))?; }
    progress(notice, "Streaming signed Watch app…");
    send_watch_bundle(&mut conn, watch_app, notice).await?;
    // Keep the forwarded connection alive until the install status is final.
    Ok(())
}

fn collect_watch_files(root: &Path, dir: &Path, items: &mut Vec<(PathBuf, String, u64)>) -> Result<(), String> {
    let entries = fs::read_dir(dir).map_err(|e| e.to_string())?;
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        let path = entry.path();
        let metadata = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
        if metadata.file_type().is_symlink() {
            return Err("Watch bundle contains a symlink, which the safe streaming installer cannot encode yet.".into());
        }
        if metadata.is_dir() { collect_watch_files(root, &path, items)?; }
        else if metadata.is_file() {
            let relative = path.strip_prefix(root).map_err(|e| e.to_string())?;
            let name = relative.to_str().ok_or("Invalid Watch filename")?.replace('\\', "/");
            if name.contains("../") || name.starts_with('/') { return Err("Unsafe Watch bundle path".into()); }
            items.push((path, name, metadata.len()));
        }
    }
    Ok(())
}

fn zip_file_header(name: &str, bytes: &[u8]) -> Result<Vec<u8>, String> {
    let size = u32::try_from(bytes.len()).map_err(|_| "Watch bundle file exceeds ZIP32 limits")?;
    let path_len = u16::try_from(name.len()).map_err(|_| "Watch bundle path is too long")?;
    let mut crc = !0u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            let mask = (crc & 1).wrapping_neg();
            crc = (crc >> 1) ^ (0xedb8_8320 & mask);
        }
    }
    let mut h = Vec::with_capacity(30 + name.len() + WATCH_ZIP_EXTRA.len());
    h.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
    h.extend_from_slice(&20u16.to_le_bytes());
    h.extend_from_slice(&0u16.to_le_bytes());
    h.extend_from_slice(&0u16.to_le_bytes());
    h.extend_from_slice(&0xbdefu16.to_le_bytes());
    h.extend_from_slice(&0x52ecu16.to_le_bytes());
    h.extend_from_slice(&(!crc).to_le_bytes());
    h.extend_from_slice(&size.to_le_bytes());
    h.extend_from_slice(&size.to_le_bytes());
    h.extend_from_slice(&path_len.to_le_bytes());
    h.extend_from_slice(&(WATCH_ZIP_EXTRA.len() as u16).to_le_bytes());
    h.extend_from_slice(name.as_bytes());
    h.extend_from_slice(WATCH_ZIP_EXTRA);
    Ok(h)
}

async fn send_watch_plist(conn: &mut Idevice, dict: Dictionary) -> Result<(), String> {
    let mut bytes = Vec::new();
    Value::Dictionary(dict).to_writer_xml(&mut bytes).map_err(|e| e.to_string())?;
    let len = u32::try_from(bytes.len()).map_err(|_| "Watch command is too large")?;
    conn.send_raw(&len.to_be_bytes()).await.map_err(|e| e.to_string())?;
    conn.send_raw(&bytes).await.map_err(|e| e.to_string())
}

async fn receive_watch_plist(conn: &mut Idevice) -> Result<Dictionary, String> {
    let n = conn.read_raw(4).await.map_err(|e| e.to_string())?;
    let length = u32::from_be_bytes([n[0], n[1], n[2], n[3]]) as usize;
    if length == 0 || length > 2 * 1024 * 1024 { return Err("Invalid Watch install response length".into()); }
    let payload = conn.read_raw(length).await.map_err(|e| e.to_string())?;
    let response: Value = plist::from_bytes(&payload).map_err(|e| e.to_string())?;
    response.into_dictionary().ok_or("Watch responded with non-dictionary plist".into())
}

async fn send_watch_bundle(conn: &mut Idevice, app: &Path, notice: Notification) -> Result<(), String> {
    if !app.is_dir() || app.extension().is_none_or(|v| v != "app") {
        return Err("Select a fully signed Watch .app bundle.".into());
    }
    if !app.join("Info.plist").is_file() || !app.join("embedded.mobileprovision").is_file() {
        return Err("Watch .app needs Info.plist and its own embedded.mobileprovision.".into());
    }
    let app_name = app.file_name().ok_or("Invalid Watch bundle name")?.to_string_lossy();
    let mut files = Vec::new();
    collect_watch_files(app, app, &mut files)?;
    files.sort_by(|a, b| a.1.cmp(&b.1));
    let total: u64 = files.iter().map(|item| item.2).sum();
    if files.len() > 30_000 || total > 1024 * 1024 * 1024 {
        return Err("Watch bundle exceeds safe transfer limits".into());
    }
    let mut options = Dictionary::new();
    options.insert("DisableDeltaTransfer".into(), Value::Integer(1.into()));
    options.insert("InstallDeltaTypeKey".into(), Value::String("InstallDeltaTypeSparseIPAFiles".into()));
    options.insert("IsUserInitiated".into(), Value::Integer(1.into()));
    options.insert("PackageType".into(), Value::String("Customer".into()));
    options.insert("PreferWifi".into(), Value::Integer(1.into()));
    let mut init = Dictionary::new();
    init.insert("InstallOptionsDictionary".into(), Value::Dictionary(options));
    init.insert("InstallTransferredDirectory".into(), Value::Integer(1.into()));
    init.insert("MediaSubdir".into(), Value::String(format!("PublicStaging/{app_name}.ipa")));
    init.insert("UserInitiatedTransfer".into(), Value::Integer(0.into()));
    send_watch_plist(conn, init).await?;
    let mut metadata = Dictionary::new();
    metadata.insert("StandardDirectoryPerms".into(), Value::Integer(16877.into()));
    metadata.insert("StandardFilePerms".into(), Value::Integer((-32348).into()));
    metadata.insert("RecordCount".into(), Value::Integer(((files.len() + 2) as i64).into()));
    metadata.insert("TotalUncompressedBytes".into(), Value::Integer((total as i64).into()));
    metadata.insert("Version".into(), Value::Integer(2.into()));
    let mut metadata_data = Vec::new();
    Value::Dictionary(metadata).to_writer_xml(&mut metadata_data).map_err(|e| e.to_string())?;
    for (name, bytes) in [
        ("META-INF/", Vec::new()),
        ("META-INF/com.apple.ZipMetadata.plist", metadata_data),
    ] {
        conn.send_raw(&zip_file_header(name, &bytes)?).await.map_err(|e| e.to_string())?;
        if !bytes.is_empty() { conn.send_raw(&bytes).await.map_err(|e| e.to_string())?; }
    }
    let mut sent: u64 = 0;
    for (path, name, size) in files {
        let data = fs::read(&path).map_err(|e| e.to_string())?;
        let destination = format!("Payload/{app_name}/{name}");
        conn.send_raw(&zip_file_header(&destination, &data)?).await.map_err(|e| e.to_string())?;
        conn.send_raw(&data).await.map_err(|e| e.to_string())?;
        sent += size;
        if total > 0 { progress(notice, &format!("Sending Watch app: {}%", sent * 100 / total)); }
    }
    conn.send_raw(WATCH_ZIP_END).await.map_err(|e| e.to_string())?;
    loop {
        let response = tokio::time::timeout(std::time::Duration::from_secs(180), receive_watch_plist(conn))
            .await.map_err(|_| "Watch installation timed out".to_string())??;
        if response.get("Status").and_then(Value::as_string) == Some("DataComplete") {
            progress(notice, "Apple Watch reported installation complete.");
            return Ok(());
        }
        let details = response.get("InstallProgressDict").and_then(Value::as_dictionary)
            .ok_or_else(|| format!("Unexpected Watch installation response: {response:?}"))?;
        if let Some(err) = details.get("Error").and_then(Value::as_string) {
            let reason = details.get("ErrorDescription").and_then(Value::as_string).unwrap_or("Unknown reason");
            return Err(format!("Watch rejected installation: {err}: {reason}"));
        }
        let percent = details.get("PercentComplete").and_then(Value::as_unsigned_integer).unwrap_or(0);
        let stage = details.get("Status").and_then(Value::as_string).unwrap_or("Installing");
        progress(notice, &format!("Apple Watch: {percent}% ({stage})"));
    }
}

/// # Safety
/// All C strings are NUL-terminated and pointers are writable. The call runs on
/// a worker thread and may block for device transport and Watch installation.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn embersign_watch_install_signed(
    pairing_path: *const c_char, device_ip: *const c_char, device_port: u16,
    host_id: *const c_char, system_buid: *const c_char,
    watch_app_path: *const c_char, status_callback: PINCallback,
    status_context: *mut c_void, error: *mut *mut c_char,
) -> i32 {
    let outcome = (|| -> Result<(), String> {
        let pairing_path = watch_arg(pairing_path, "pairing path")?;
        let device_ip = watch_arg(device_ip, "Device IP")?;
        let host_id = watch_arg(host_id, "host identifier")?;
        let system_buid = watch_arg(system_buid, "system identifier")?;
        let watch_path = watch_arg(watch_app_path, "Watch bundle path")?;
        if device_port == 0 { return Err("Missing pairing port".into()); }
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()
            .map_err(|e| e.to_string())?;
        runtime.block_on(watch_install(&pairing_path, &device_ip, device_port,
            &host_id, &system_buid, Path::new(&watch_path),
            Notification { callback: status_callback, context: status_context }))
    })();
    match outcome {
        Ok(()) => 0,
        Err(message) => { failure(error, &message); 1 }
    }
}
