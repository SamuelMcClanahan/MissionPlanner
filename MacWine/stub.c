/*
 * Main executable of "Mission Planner.app" (Wine bundle).
 *
 * It runs Contents/Resources/launcher.sh with /bin/bash and waits for it.
 * A compiled, signed main executable (instead of the script itself) makes
 * macOS treat Mission Planner as the responsible app for everything the
 * launcher starts, so privacy prompts (Documents folder, local network) name
 * Mission Planner and not /bin/bash.
 *
 * Build: clang -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 -o MissionPlanner stub.c
 */
#include <errno.h>
#include <libgen.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

extern char **environ;

static pid_t child = -1;

static void forward_signal(int sig)
{
    if (child > 0)
        kill(child, sig);
}

static int executable_path(char *buf, size_t len)
{
#ifdef __APPLE__
    char raw[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0)
        return -1;
    return realpath(raw, buf) ? 0 : -1;
#else
    ssize_t n = readlink("/proc/self/exe", buf, len - 1);
    if (n < 0)
        return -1;
    buf[n] = '\0';
    return 0;
#endif
}

int main(int argc, char *argv[])
{
    char exe[PATH_MAX], dir[PATH_MAX], script[PATH_MAX];
    if (executable_path(exe, sizeof(exe)) != 0) {
        fprintf(stderr, "MissionPlanner: cannot find own path\n");
        return 1;
    }
    /* exe = .../Contents/MacOS/MissionPlanner -> .../Contents/Resources/launcher.sh */
    strncpy(dir, exe, sizeof(dir) - 1);
    dir[sizeof(dir) - 1] = '\0';
    char contents[PATH_MAX];
    strncpy(contents, dirname(dir), sizeof(contents) - 1);
    contents[sizeof(contents) - 1] = '\0';
    snprintf(script, sizeof(script), "%s/Resources/launcher.sh", dirname(contents));

    char **args = calloc((size_t)argc + 2, sizeof(char *));
    if (!args)
        return 1;
    args[0] = "/bin/bash";
    args[1] = script;
    for (int i = 1; i < argc; i++)
        args[i + 1] = argv[i];

    /* Pass quit and terminate requests on to the launcher. */
    signal(SIGTERM, forward_signal);
    signal(SIGINT, forward_signal);
    signal(SIGHUP, forward_signal);

    int err = posix_spawn(&child, "/bin/bash", NULL, NULL, args, environ);
    if (err != 0) {
        fprintf(stderr, "MissionPlanner: cannot start launcher: %s\n", strerror(err));
        return 1;
    }

    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR)
            return 1;
    }
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
}
