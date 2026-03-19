/*
 * tmux-attach-helper: Sets up a controlling terminal then exec's tmux.
 *
 * SwiftTerm's Subprocess path (Swift 6.1+) uses POSIX_SPAWN_SETSID which
 * creates a new session but doesn't call TIOCSCTTY, so the child process
 * has no controlling terminal. tmux requires /dev/tty to work.
 *
 * This helper: setsid() -> open slave tty -> TIOCSCTTY -> exec tmux.
 *
 * Usage: tmux-attach-helper <tmux-path> <args...>
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <fcntl.h>

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: tmux-attach-helper <tmux-path> [args...]\n");
        return 1;
    }

    /* Get the tty name before setsid (stdin is the PTY slave from SwiftTerm) */
    char *tty_name = ttyname(STDIN_FILENO);
    if (!tty_name) {
        perror("ttyname");
        return 1;
    }

    /* Create a new session so we can acquire a controlling terminal */
    if (setsid() == -1) {
        /* Already a session leader — that's fine, continue */
    }

    /* Open the tty to acquire it as controlling terminal */
    int fd = open(tty_name, O_RDWR);
    if (fd < 0) {
        perror("open tty");
        return 1;
    }

    /* Set as controlling terminal */
    if (ioctl(fd, TIOCSCTTY, 0) == -1) {
        perror("TIOCSCTTY");
        /* Non-fatal — try to continue anyway */
    }
    close(fd);

    /* Exec tmux with the remaining arguments */
    execvp(argv[1], &argv[1]);
    perror("execvp");
    return 1;
}
