package main

import (
	"crypto/sha256"
	"encoding/hex"
	"log"
	"net/http"
	"sort"
	"strings"
)

// Log lines on this server end up in the package log on the NAS, which other DSM apps,
// lower-privilege shell accounts and emailed support bundles can read. A DSM SID is a
// complete credential here (getWebAPISession accepts it from a query param, form field or
// cookie and mints a JWT for it), and DSM login forms carry passwd/otp_code. So the rule for
// every request-shaped log line is: method, path and header NAMES are fine; query strings,
// bodies, cookie VALUES and session ids are not (TASK-929).

// logUnhandledRequest is the router's catch-all. It exists to spot DS Video paths we do not
// serve yet, which the method and path alone are enough for. It runs BELOW restoreTrueURL,
// so req.URL is the true, un-redacted URL: logging req.URL.String() or the body wrote live
// _sid values and passwd form fields into the NAS log.
func logUnhandledRequest(w http.ResponseWriter, req *http.Request) {
	log.Printf("[WebAPI] UNHANDLED %s %s UA=%q", req.Method, req.URL.Path, req.Header.Get("User-Agent"))
	http.NotFound(w, req)
}

// sidFingerprint names a session id in a log line without revealing it. The old 16-character
// prefix printed the WHOLE id whenever it was 16 characters or shorter (DSM 6 SIDs can be
// 13) and most of it otherwise. A truncated SHA-256 still lets two log lines be matched up.
func sidFingerprint(sid string) string {
	if sid == "" {
		return "none"
	}
	sum := sha256.Sum256([]byte(sid))
	return "fp:" + hex.EncodeToString(sum[:4])
}

// cookieNames lists the names in a Cookie header, never the values: enough to see whether a
// client sent `id=` under a different name, without writing other sessions' cookies to disk.
func cookieNames(header string) string {
	var names []string
	for _, part := range strings.Split(header, ";") {
		name, _, _ := strings.Cut(strings.TrimSpace(part), "=")
		if name = strings.TrimSpace(name); name != "" {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return strings.Join(names, ",")
}
