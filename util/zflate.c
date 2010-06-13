/*
--------------------
% cc zflate.c -lz -ozflate
% echo 'Hi.' | ./zflate -d | ./zflate -i
Hi.
% _
--------------------
 */

#include <stdio.h>
#include <stdlib.h>
#include <sysexits.h>

#include <unistd.h>
#include <zlib.h>


enum { BUFFER_SIZE = 1024 };

static void show_usage(FILE *out);
static void deflate_stream(FILE *source, FILE *sink);
static void inflate_stream(FILE *source, FILE *sink);


int main(int argc, char *argv[])
{
    enum program_mode
    {
        MODE_UNSPECIFIED,
        MODE_DEFLATE,
        MODE_INFLATE
    };
    enum program_mode mode   = MODE_UNSPECIFIED;
    FILE             *source = stdin;
    FILE             *sink   = stdout;
    int               optchar;

    /*
     * Get options
     */
    while ((optchar = getopt(argc, argv, "dih")) != -1)
    {
        switch (optchar)
        {
            case 'd': mode = MODE_DEFLATE; break;
            case 'i': mode = MODE_INFLATE; break;

            case 'h':
                show_usage(stdout);
                exit(EXIT_SUCCESS);

            default:
                show_usage(stderr);
                exit(EX_USAGE);
        }
    }
    argc -= optind;
    argv += optind;

    switch (mode)
    {
        case MODE_UNSPECIFIED:
            (void) fputs("Operation mode is not specified.\n", stderr);
            show_usage(stderr);
            exit(EX_USAGE);

        case MODE_DEFLATE: deflate_stream(source, sink); break;
        case MODE_INFLATE: inflate_stream(source, sink); break;
    }

    return EXIT_SUCCESS;
}


/*----------------------------------------------------------------------------*/

static void show_usage(FILE *out)
{
    static const char const *usage_lines[] =
    {
        "Usage: zflate mode",
        "",
        "Modes:",
        "  -d   Deflate stdin to stdout",
        "  -i   Inflate stdin to stdout",
        "  -h   Print this message and exit"
    };
    enum { NLINES = sizeof(usage_lines) / sizeof(char*) };
    size_t i;

    for (i = 0; i < NLINES; ++i)
    {
        if (fprintf(out, "%s\n", usage_lines[i]) < 0)
        {
            perror("could not print usage");
            exit(EX_IOERR);
        }
    }
}


/*----------------------------------------------------------------------------*/

static void deflate_stream(FILE *source, FILE *sink)
{
    Bytef    srcbuf[BUFFER_SIZE];   /* where to store input data */
    Bytef    dstbuf[BUFFER_SIZE];   /* where to store compressed data */
    z_stream stream;
    int      atend = 0;     /* set to nonzero when the compression stream is finished */
    int      zstat = 0;     /* status code returned by zlib functions */
    int      zmode = 0;     /* deflation mode (Z_NO_FLUSH or Z_FINISH) */

    if (isatty(fileno(sink)))
    {
        (void) fputs("Attempted to write deflated data to the terminal!\n", stderr);
        exit(EX_USAGE);
    }

    /*
     * Use the default allocators.
     */
    stream.zalloc = Z_NULL;
    stream.zfree  = Z_NULL;
    stream.opaque = Z_NULL;

    zstat = deflateInit(&stream, Z_DEFAULT_COMPRESSION);
    if (zstat < 0)
    {
        (void) fprintf(stderr, "Failed to start compression: %s\n", stream.msg);
        goto L_zlib_error;
    }

    /*
     * Start stream deflation.
     */
    stream.avail_in  = 0;
    stream.next_out  = dstbuf;
    stream.avail_out = sizeof(dstbuf);
    zmode            = Z_NO_FLUSH;

    while (!atend)
    {
        if (!feof(source) && stream.avail_in == 0)
        {
            /* We have used the entire buffer.  Read in next chunk. */
            const size_t nread = fread(srcbuf, 1, sizeof(srcbuf), source);
            stream.next_in  = srcbuf;
            stream.avail_in = nread;

            if (ferror(source))
            {
                perror("reading input");
                goto L_io_error;
            }

            if (feof(source))
                /* This is the final chunk. */
                zmode = Z_FINISH;
        }

        zstat = deflate(&stream, zmode);
        switch (zstat)
        {
            case Z_OK:
                break;

            case Z_STREAM_END:
                atend = 1;
                break;

            default:
                (void) fprintf(stderr, "Failed to compress data: %s\n", stream.msg);
                goto L_zlib_error;
        }

        if (stream.avail_out == 0 || atend)
        {
            const size_t ntowrite = sizeof(dstbuf) - stream.avail_out;
            const size_t nwritten = fwrite(dstbuf, 1, ntowrite, sink);

            if (nwritten < ntowrite)
            {
                perror("writing compressed data");
                goto L_io_error;
            }

            /*
             * Reuse the output buffer.
             */
            stream.next_out  = dstbuf;
            stream.avail_out = sizeof(dstbuf);
        }
    }

    /*
     * Finished.
     */
    zstat = deflateEnd(&stream);
    switch (zstat)
    {
        case Z_OK:
            break;

        case Z_DATA_ERROR:
            (void) fputs("Warning: The output should be incomplete!\n", stderr);
        default:
            (void) fprintf(stderr, "Failed to finish compression: %s\n", stream.msg);
            exit(EX_SOFTWARE);
    }
    return; /* success */

L_io_error:
    (void) deflateEnd(&stream);
    exit(EX_IOERR);

L_zlib_error:
    (void) deflateEnd(&stream);
    exit(EXIT_FAILURE);
}


/*----------------------------------------------------------------------------*/

static void inflate_stream(FILE *source, FILE *sink)
{
    Bytef    srcbuf[BUFFER_SIZE];   /* where to store compressed input data */
    Bytef    dstbuf[BUFFER_SIZE];   /* where to store decompressed data */
    z_stream stream;
    int      atend   = 0;           /* set to nonzero when the compression stream is finished */
    int      zstat   = 0;           /* status code returned by zlib functions */
    unsigned nbuferr = 0;           /* number of occurrence of Z_BUF_ERROR */

    if (isatty(fileno(source)))
    {
        (void) fputs("Attempted to input deflated data from the terminal!?\n", stderr);
        exit(EX_USAGE);
    }

    /*
     * Use the default allocators.
     */
    stream.zalloc = Z_NULL;
    stream.zfree  = Z_NULL;
    stream.opaque = Z_NULL;

    zstat = inflateInit(&stream);
    if (zstat < 0)
    {
        (void) fprintf(stderr, "Failed to start decompression: %s\n", stream.msg);
        goto L_zlib_error;
    }

    /*
     * Start decompression.
     */
    stream.avail_in = 0;
    stream.next_out = dstbuf;
    stream.avail_out = sizeof(dstbuf);

    while (!atend)
    {
        if (!feof(source) && stream.avail_in == 0)
        {
            /* We have used the entire buffer.  Read in next chunk. */
            const size_t nread = fread(srcbuf, 1, sizeof(srcbuf), source);
            stream.next_in = srcbuf;
            stream.avail_in = nread;

            if (ferror(source))
            {
                perror("reading input");
                goto L_io_error;
            }
        }

        zstat = inflate(&stream, Z_NO_FLUSH);
        switch (zstat)
        {
            case Z_OK:
                break;

            case Z_BUF_ERROR:
                if (++nbuferr > 8)
                {
                    /* zlib infinitely produces Z_BUF_ERROR for some kind of corrupted input */
                    (void) fputs("Too many buffer error. The input data may be corrupted?\n", stderr);
                    goto L_zlib_error;
                }
                break;

            case Z_STREAM_END:
                atend = 1;
                break;

            case Z_DATA_ERROR:
                (void) fprintf(stderr, "Corrupted input data: %s\n", stream.msg);
                goto L_zlib_error;

            default:
                (void) fprintf(stderr, "Failed to decompress data (%d): %s\n", zstat, stream.msg);
                goto L_zlib_error;
        }

        if (stream.avail_out == 0 || atend)
        {
            const size_t ntowrite = sizeof(dstbuf) - stream.avail_out;
            const size_t nwritten = fwrite(dstbuf, 1, ntowrite, sink);

            if (nwritten < ntowrite)
            {
                perror("writing decompressed data");
                goto L_io_error;
            }

            /*
             * Reuse the output buffer.
             */
            stream.next_out = dstbuf;
            stream.avail_out = sizeof(dstbuf);
        }
    }

    /*
     * Finished.
     */
    zstat = inflateEnd(&stream);
    switch (zstat)
    {
        case Z_OK:
            break;

        default:
            (void) fprintf(stderr, "Failed to finish compression: %s\n", stream.msg);
            exit(EX_SOFTWARE);
    }

    return; /* success */

L_io_error:
    (void) inflateEnd(&stream);
    exit(EX_IOERR);

L_zlib_error:
    (void) inflateEnd(&stream);
    exit(EX_SOFTWARE);
}

