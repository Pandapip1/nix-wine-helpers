/*
 * nix-wine-exec: run a command with a private, writable overlay of a
 * (read-only) wine prefix, without needing root, a setuid helper or a
 * persistent mount point.
 *
 *   nix-wine-exec --lower PREFIX --upper UPPER --work WORK
 *                 [--bind SRC=REL]... [--copy-up REL]... [--symlink REL=TARGET]... [--env NAME] [--mountpoint DIR]
 *                 -- cmd args...
 *
 * An overlayfs (PREFIX below, UPPER above) is created with the new mount API
 * (fsopen/fsmount) inside a fresh user+mount namespace in which the caller's
 * uid/gid map to themselves. By default the resulting mount is left
 * *detached*: it is not attached anywhere in the filesystem, and is reachable
 * only through an inherited fd, exposed to the child as /proc/self/fd/N in the
 * environment variable NAME (default WINEPREFIX). With --mountpoint it is
 * attached at DIR (inside the private mount namespace) instead.
 *
 * Directories in the Nix store are read-only (0555) and overlayfs shows
 * lower-only directories with the lower mode, so the upper layer is seeded
 * with a 0755 skeleton of every directory in the lower layer (idempotent).
 * --copy-up REL additionally copies a lower file into the upper layer
 * (mode 0644) so that it can be rewritten in place, e.g. the registry hives.
 *
 * --symlink REL=TARGET creates a symlink in the upper layer if REL does not
 * already exist there (e.g. dosdevices/z: -> /, which is kept out of the
 * prefix itself so the Nix store never holds a link to outside the store).
 *
 * Each --bind SRC=REL clones the tree at SRC (recursively) onto REL, a path
 * relative to the overlay root, creating REL in the upper layer if needed.
 * Binds are applied in order, so nested binds (a $HOME bind with XDG
 * directories bound inside it) work, which symlinks cannot do.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_BINDS 64

static const char *g_lower, *g_upper;
static size_t g_lower_len;

static void die(const char *what)
{
    fprintf(stderr, "nix-wine-exec: %s: %s\n", what, strerror(errno));
    exit(125);
}

static void write_file(const char *path, const char *data)
{
    int fd = open(path, O_WRONLY);
    if (fd < 0) die(path);
    if (write(fd, data, strlen(data)) < 0) die(path);
    close(fd);
}

static void mkdirs_at(int dirfd, const char *rel)
{
    char *p = strdup(rel);
    for (char *s = p; *s; s++) {
        if (*s != '/' || s == p) continue;
        *s = 0;
        if (mkdirat(dirfd, p, 0755) < 0 && errno != EEXIST) die(p);
        *s = '/';
    }
    if (mkdirat(dirfd, p, 0755) < 0 && errno != EEXIST) die(p);
    free(p);
}

static int seed_dir(const char *path, const struct stat *st, int type, struct FTW *ftw)
{
    (void)st; (void)ftw;
    if (type != FTW_D) return 0;
    char *dst;
    if (asprintf(&dst, "%s%s", g_upper, path + g_lower_len) < 0) die("asprintf");
    if (mkdir(dst, 0755) < 0 && errno != EEXIST) die(dst);
    free(dst);
    return 0;
}

static void copy_up(const char *rel)
{
    char *src, *dst, buf[65536];
    if (asprintf(&src, "%s/%s", g_lower, rel) < 0 || asprintf(&dst, "%s/%s", g_upper, rel) < 0) die("asprintf");
    if (access(dst, F_OK) == 0) goto out; /* already present, keep user changes */
    int in = open(src, O_RDONLY);
    if (in < 0) { if (errno == ENOENT) goto out; die(src); }
    int o = open(dst, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (o < 0) die(dst);
    ssize_t n;
    while ((n = read(in, buf, sizeof buf)) > 0)
        if (write(o, buf, n) != n) die(dst);
    close(in); close(o);
out:
    free(src); free(dst);
}

int main(int argc, char **argv)
{
    const char *lower = NULL, *upper = NULL, *work = NULL;
    const char *envname = "WINEPREFIX", *mountpoint = NULL;
    char *bind_src[MAX_BINDS], *bind_rel[MAX_BINDS];
    char *copyups[MAX_BINDS], *link_rel[MAX_BINDS], *link_target[MAX_BINDS];
    int nbinds = 0, ncopy = 0, nlinks = 0, i;

    for (i = 1; i < argc; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--")) { i++; break; }
        else if (!strcmp(a, "--lower") && i + 1 < argc) lower = argv[++i];
        else if (!strcmp(a, "--upper") && i + 1 < argc) upper = argv[++i];
        else if (!strcmp(a, "--work") && i + 1 < argc) work = argv[++i];
        else if (!strcmp(a, "--env") && i + 1 < argc) envname = argv[++i];
        else if (!strcmp(a, "--mountpoint") && i + 1 < argc) mountpoint = argv[++i];
        else if (!strcmp(a, "--copy-up") && i + 1 < argc && ncopy < MAX_BINDS) copyups[ncopy++] = argv[++i];
        else if (!strcmp(a, "--symlink") && i + 1 < argc && nlinks < MAX_BINDS) {
            char *eq = strchr(argv[++i], '=');
            if (!eq) { fprintf(stderr, "nix-wine-exec: bad --symlink\n"); return 2; }
            *eq = 0;
            link_rel[nlinks] = argv[i];
            link_target[nlinks++] = eq + 1;
        }
        else if (!strcmp(a, "--bind") && i + 1 < argc) {
            char *eq = strchr(argv[++i], '=');
            if (!eq || nbinds == MAX_BINDS) { fprintf(stderr, "nix-wine-exec: bad --bind\n"); return 2; }
            *eq = 0;
            bind_src[nbinds] = argv[i];
            bind_rel[nbinds++] = eq + 1;
        } else { fprintf(stderr, "nix-wine-exec: unknown argument %s\n", a); return 2; }
    }
    if (!lower || !upper || !work || i >= argc) {
        fprintf(stderr, "usage: nix-wine-exec --lower P --upper U --work W [--bind SRC=REL]... [--copy-up REL]... [--symlink REL=TARGET]... [--env NAME] [--mountpoint DIR] -- cmd...\n");
        return 2;
    }

    g_lower = lower; g_upper = upper; g_lower_len = strlen(lower);
    if (nftw(lower, seed_dir, 32, FTW_PHYS) < 0) die("seeding upper layer");
    for (int c = 0; c < ncopy; c++) copy_up(copyups[c]);
    for (int l = 0; l < nlinks; l++) {
        char *dst;
        if (asprintf(&dst, "%s/%s", upper, link_rel[l]) < 0) die("asprintf");
        if (symlink(link_target[l], dst) < 0 && errno != EEXIST) die(dst);
        free(dst);
    }

    /* new user namespace mapping our ids to themselves, plus a private mount ns */
    uid_t uid = getuid();
    gid_t gid = getgid();
    if (unshare(CLONE_NEWUSER | CLONE_NEWNS) < 0) die("unshare");
    char map[64];
    write_file("/proc/self/setgroups", "deny");
    snprintf(map, sizeof map, "%u %u 1", uid, uid);
    write_file("/proc/self/uid_map", map);
    snprintf(map, sizeof map, "%u %u 1", gid, gid);
    write_file("/proc/self/gid_map", map);

    int fs = fsopen("overlay", FSOPEN_CLOEXEC);
    if (fs < 0) die("fsopen(overlay)");
    if (fsconfig(fs, FSCONFIG_SET_STRING, "lowerdir", lower, 0) < 0) die("lowerdir");
    if (fsconfig(fs, FSCONFIG_SET_STRING, "upperdir", upper, 0) < 0) die("upperdir");
    if (fsconfig(fs, FSCONFIG_SET_STRING, "workdir", work, 0) < 0) die("workdir");
    if (fsconfig(fs, FSCONFIG_SET_FLAG, "userxattr", NULL, 0) < 0) die("userxattr");
    if (fsconfig(fs, FSCONFIG_CMD_CREATE, NULL, NULL, 0) < 0) die("create overlay");
    int root = fsmount(fs, FSMOUNT_CLOEXEC, 0);
    if (root < 0) die("fsmount");
    close(fs);

    for (int b = 0; b < nbinds; b++) {
        mkdirs_at(root, bind_rel[b]);
        int tree = open_tree(AT_FDCWD, bind_src[b],
                             OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC | AT_RECURSIVE);
        if (tree < 0) die(bind_src[b]);
        if (move_mount(tree, "", root, bind_rel[b], MOVE_MOUNT_F_EMPTY_PATH) < 0)
            die(bind_rel[b]);
        close(tree);
    }

    char path[64];
    if (mountpoint) {
        if (move_mount(root, "", AT_FDCWD, mountpoint, MOVE_MOUNT_F_EMPTY_PATH) < 0)
            die(mountpoint);
        setenv(envname, mountpoint, 1);
    } else {
        int fl = fcntl(root, F_GETFD);
        if (fl < 0 || fcntl(root, F_SETFD, fl & ~FD_CLOEXEC) < 0) die("fcntl");
        snprintf(path, sizeof path, "/proc/self/fd/%d", root);
        setenv(envname, path, 1);
    }

    execvp(argv[i], &argv[i]);
    die(argv[i]);
    return 125;
}
