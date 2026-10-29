// SPDX-License-Identifier: MIT
// An on-device iOS 27 remote-pairing host. The API never returns a private key
// until Apple has completed the user-approved pairing handshake.
#ifndef EMBER_PAIRING_NATIVE_H
#define EMBER_PAIRING_NATIVE_H

#include <stddef.h>
#include <stdint.h>

typedef struct EmberPairingSession EmberPairingSession;
typedef void (*EmberPairingPINCallback)(const char *pin, void *context);

EmberPairingSession *embersign_pair_start(const char *host_name, char **error);
uint16_t embersign_pair_port(const EmberPairingSession *session);
const char *embersign_pair_service_name(const EmberPairingSession *session);
size_t embersign_pair_txt_count(const EmberPairingSession *session);
const char *embersign_pair_txt_key(const EmberPairingSession *session, size_t index);
const char *embersign_pair_txt_value(const EmberPairingSession *session, size_t index);

// Blocking call. Returns 0 on success, 1 on failure, 2 on cancellation.
// The returned pairing bytes and strings belong to the caller until freed.
int32_t embersign_pair_wait(const EmberPairingSession *session,
                            EmberPairingPINCallback on_pin,
                            void *context,
                            uint8_t **pairing_bytes,
                            size_t *pairing_length,
                            char **device_name,
                            char **error);
void embersign_pair_cancel(const EmberPairingSession *session);
// Call destroy only after embersign_pair_wait returns.
void embersign_pair_destroy(EmberPairingSession *session);
void embersign_pair_free_bytes(uint8_t *bytes, size_t length);
void embersign_pair_free_string(char *text);

// Discover the Watch UDIDs seen through the paired iPhone, over the existing
// LocalDevVPN + remote-pairing tunnel. No external server or PC is required.
// The returned comma-separated UDIDs are freed with embersign_pair_free_string.
int32_t embersign_watch_discover(const char *pairing_path,
                                 const char *device_ip, uint16_t device_port,
                                 char **iphone_udid, char **watch_udids,
                                 char **error);

// Install an ALREADY-SIGNED Watch .app using watchOS's streaming_zip_conduit.
// This does not sign an IPA, provision devices, or install the iPhone host.
// Returns success only after watchOS reports DataComplete.
int32_t embersign_watch_install_signed(const char *pairing_path,
                                       const char *device_ip, uint16_t device_port,
                                       const char *host_id, const char *system_buid,
                                       const char *watch_app_path,
                                       EmberPairingPINCallback status_callback,
                                       void *status_context, char **error);

#endif
