#ifndef NOSTR_VPN_APP_CORE_C_H
#define NOSTR_VPN_APP_CORE_C_H

#include <stdint.h>

typedef struct NvpnAppHandle NvpnAppHandle;

NvpnAppHandle *nostr_vpn_app_new(const char *data_dir, const char *app_version);
void nostr_vpn_app_free(NvpnAppHandle *handle);

char *nostr_vpn_app_state_json(const NvpnAppHandle *handle);
char *nostr_vpn_app_refresh_json(const NvpnAppHandle *handle);
char *nostr_vpn_app_dispatch_json(const NvpnAppHandle *handle, const char *action_json);

char *nostr_vpn_qr_matrix_json(const char *text);
char *nostr_vpn_decode_qr_image_json(const char *path);
void nostr_vpn_string_free(char *value);

#endif
