#ifndef MC_CURL_SHIM_H
#define MC_CURL_SHIM_H

#include <curl/curl.h>
#include <stddef.h>

// curl_easy_setopt and curl_easy_getinfo are variadic, so Swift cannot call them directly.
typedef size_t (*mc_data_cb)(char *buffer, size_t size, size_t count, void *user);
typedef int (*mc_progress_cb)(void *user, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow);

CURLcode mc_set_long(CURL *handle, CURLoption option, long value);
CURLcode mc_set_offset(CURL *handle, CURLoption option, curl_off_t value);
CURLcode mc_set_string(CURL *handle, CURLoption option, const char *value);
CURLcode mc_set_pointer(CURL *handle, CURLoption option, void *value);
CURLcode mc_set_write(CURL *handle, mc_data_cb callback, void *user);
CURLcode mc_set_read(CURL *handle, mc_data_cb callback, void *user);
CURLcode mc_set_progress(CURL *handle, mc_progress_cb callback, void *user);

#endif
