#include "shim.h"

CURLcode mc_set_long(CURL *handle, CURLoption option, long value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode mc_set_offset(CURL *handle, CURLoption option, curl_off_t value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode mc_set_string(CURL *handle, CURLoption option, const char *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode mc_set_pointer(CURL *handle, CURLoption option, void *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode mc_set_write(CURL *handle, mc_data_cb callback, void *user) {
    curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, callback);
    return curl_easy_setopt(handle, CURLOPT_WRITEDATA, user);
}

CURLcode mc_set_read(CURL *handle, mc_data_cb callback, void *user) {
    curl_easy_setopt(handle, CURLOPT_READFUNCTION, callback);
    return curl_easy_setopt(handle, CURLOPT_READDATA, user);
}

CURLcode mc_set_progress(CURL *handle, mc_progress_cb callback, void *user) {
    curl_easy_setopt(handle, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(handle, CURLOPT_XFERINFOFUNCTION, callback);
    return curl_easy_setopt(handle, CURLOPT_XFERINFODATA, user);
}
