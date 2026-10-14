#ifndef CCURL_H
#define CCURL_H

#include <curl/curl.h>

// Non-variadic wrappers so Swift can call curl_easy_setopt / curl_easy_getinfo.
CURLcode ccurl_setopt_long(CURL *h, CURLoption opt, long value);
CURLcode ccurl_setopt_off(CURL *h, CURLoption opt, curl_off_t value);
CURLcode ccurl_setopt_ptr(CURL *h, CURLoption opt, const void *value);
CURLcode ccurl_setopt_str(CURL *h, CURLoption opt, const char *value);
CURLcode ccurl_setopt_slist(CURL *h, CURLoption opt, struct curl_slist *value);

typedef size_t (*ccurl_data_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);
typedef int (*ccurl_xferinfo_cb)(void *userdata, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow);
typedef int (*ccurl_debug_cb)(CURL *h, curl_infotype type, char *data, size_t size, void *userdata);

CURLcode ccurl_set_write(CURL *h, ccurl_data_cb cb, void *userdata);
CURLcode ccurl_set_read(CURL *h, ccurl_data_cb cb, void *userdata);
CURLcode ccurl_set_header(CURL *h, ccurl_data_cb cb, void *userdata);
CURLcode ccurl_set_xferinfo(CURL *h, ccurl_xferinfo_cb cb, void *userdata);
CURLcode ccurl_set_debug(CURL *h, ccurl_debug_cb cb, void *userdata);

long ccurl_response_code(CURL *h);
curl_off_t ccurl_size_download(CURL *h);

#endif
