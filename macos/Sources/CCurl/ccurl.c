#include "ccurl.h"

CURLcode ccurl_setopt_long(CURL *h, CURLoption opt, long value) { return curl_easy_setopt(h, opt, value); }
CURLcode ccurl_setopt_off(CURL *h, CURLoption opt, curl_off_t value) { return curl_easy_setopt(h, opt, value); }
CURLcode ccurl_setopt_ptr(CURL *h, CURLoption opt, const void *value) { return curl_easy_setopt(h, opt, value); }
CURLcode ccurl_setopt_str(CURL *h, CURLoption opt, const char *value) { return curl_easy_setopt(h, opt, value); }
CURLcode ccurl_setopt_slist(CURL *h, CURLoption opt, struct curl_slist *value) { return curl_easy_setopt(h, opt, value); }

CURLcode ccurl_set_write(CURL *h, ccurl_data_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, cb);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_WRITEDATA, userdata);
}
CURLcode ccurl_set_read(CURL *h, ccurl_data_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_READFUNCTION, cb);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_READDATA, userdata);
}
CURLcode ccurl_set_header(CURL *h, ccurl_data_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, cb);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_HEADERDATA, userdata);
}
CURLcode ccurl_set_xferinfo(CURL *h, ccurl_xferinfo_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, cb);
    if (rc) return rc;
    rc = curl_easy_setopt(h, CURLOPT_XFERINFODATA, userdata);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
}
CURLcode ccurl_set_debug(CURL *h, ccurl_debug_cb cb, void *userdata) {
    CURLcode rc = curl_easy_setopt(h, CURLOPT_DEBUGFUNCTION, cb);
    if (rc) return rc;
    rc = curl_easy_setopt(h, CURLOPT_DEBUGDATA, userdata);
    return rc ? rc : curl_easy_setopt(h, CURLOPT_VERBOSE, 1L);
}

long ccurl_response_code(CURL *h) { long c = 0; curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &c); return c; }
curl_off_t ccurl_size_download(CURL *h) { curl_off_t s = 0; curl_easy_getinfo(h, CURLINFO_SIZE_DOWNLOAD_T, &s); return s; }
