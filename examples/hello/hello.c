#include <stdio.h>
#include <stdlib.h>

/* Writes a file into the Windows Documents folder and reports what it sees. */
int main(int argc, char **argv)
{
    const char *profile = getenv("USERPROFILE");
    char path[512];
    snprintf(path, sizeof path, "%s\\Documents\\hello-from-wine.txt", profile ? profile : "C:");
    FILE *f = fopen(path, "w");
    printf("USERPROFILE=%s\n", profile ? profile : "(unset)");
    if (!f) { printf("cannot write %s\n", path); return 1; }
    fprintf(f, "hello from a bundled wine prefix (%d args)\n", argc - 1);
    fclose(f);
    printf("wrote %s\n", path);
    FILE *z = fopen("Z:\\etc\\hostname", "r");
    printf("Z: drive %s\n", z ? "reachable" : "missing");
    return 0;
}
