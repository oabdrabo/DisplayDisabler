// DisplayDisabler scripting-addition payload.
// Runs inside Dock (dlopen'd by the injected loader). Listens on a private
// unix socket and applies window opacity via Dock's privileged WindowServer
// connection. Socket/opcode wire-format is compatible with the yabai
// scripting addition (MIT) so the protocol matches our in-app client.

#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>

#define SA_SOCKET_PATH_FMT       "/tmp/displaydisabler-sa_%s.socket"
#define SA_SOCKET_BUFF_LEN       0x1000
#define SA_OPCODE_WINDOW_OPACITY 0x07

extern int     SLSMainConnectionID(void);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);

#define unpack(v) memcpy(&v, message, sizeof(v)); message += sizeof(v)

static int daemon_sockfd;
static pthread_t daemon_thread;

static void do_window_opacity(char *message) {
    uint32_t wid;
    unpack(wid);
    if (!wid) return;
    float alpha;
    unpack(alpha);
    SLSSetWindowAlpha(SLSMainConnectionID(), wid, alpha);
}

static void handle_message(char *message) {
    int op = *message++;
    if (op == SA_OPCODE_WINDOW_OPACITY) do_window_opacity(message);
}

static inline bool read_message(int sockfd, char *message) {
    int bytes_read = 0, bytes_to_read = 0;
    if (read(sockfd, &bytes_to_read, sizeof(int16_t)) != sizeof(int16_t)) return false;
    if (bytes_to_read >= SA_SOCKET_BUFF_LEN || bytes_to_read <= 0) return false;
    do {
        int cur = (int)read(sockfd, message + bytes_read, bytes_to_read - bytes_read);
        if (cur <= 0) break;
        bytes_read += cur;
    } while (bytes_read < bytes_to_read);
    return bytes_read == bytes_to_read;
}

static void *handle_connection(void *unused) {
    (void)unused;
    for (;;) {
        int sockfd = accept(daemon_sockfd, NULL, 0);
        if (sockfd == -1) continue;
        char message[SA_SOCKET_BUFF_LEN];
        if (read_message(sockfd, message)) handle_message(message);
        shutdown(sockfd, SHUT_RDWR);
        close(sockfd);
    }
    return NULL;
}

static bool start_daemon(const char *socket_path) {
    struct sockaddr_un addr;
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socket_path);
    unlink(socket_path);

    if ((daemon_sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) return false;
    if (bind(daemon_sockfd, (struct sockaddr *)&addr, sizeof(addr)) == -1) return false;
    if (chmod(socket_path, 0600) != 0) return false;
    if (listen(daemon_sockfd, SOMAXCONN) == -1) return false;

    pthread_create(&daemon_thread, NULL, &handle_connection, NULL);
    return true;
}

__attribute__((constructor))
static void load_payload(void) {
    NSLog(@"[displaydisabler-sa] payload loaded into pid %d", getpid());
    const char *user = getenv("USER");
    if (!user) {
        NSLog(@"[displaydisabler-sa] no USER in env; abort");
        return;
    }
    char socket_file[255];
    snprintf(socket_file, sizeof(socket_file), SA_SOCKET_PATH_FMT, user);
    if (start_daemon(socket_file)) {
        NSLog(@"[displaydisabler-sa] listening on %s", socket_file);
    } else {
        NSLog(@"[displaydisabler-sa] failed to start daemon");
    }
}
