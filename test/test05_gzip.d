
import std.algorithm;
import std.array;
import std.range;
import std.stdio;

import etc.c.zlib;


void main()
{
    auto gzinfo = GzipInfo("test05-out.txt", 0, Filesystem.Unix);
    auto gz = withGzip(rawWriter(File("test05-out.gz", "wb")), gzinfo);
    foreach (ubyte[] e; File(__FILE__).byChunk(512))
        gz.put(e);
//    copy(File(__FILE__).byChunk(512), gz);
    gz.flush;
    gz.close;
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

RawWriter!(Device) rawWriter(Device)(Device dev)
{
    return RawWriter!(Device)(dev);
}

struct RawWriter(Device)
{
    void put(T)(T e)
    {
        device_.rawWrite(e);
    }

private:
    Device device_;
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

auto withDeflate(R)(R r, int level = 6)
    if (isOutputRange!(R, ubyte[]))
{
    auto z = DeflatedOutput!(R, StreamFormat.zlib)(r);
    z.openZ(level);
    return z;
}

auto withGzip(R)(R r, GzipInfo info, int level = 6)
    if (isOutputRange!(R, ubyte[]))
{
    auto z = DeflatedOutput!(R, StreamFormat.gzip)(r);
    z.openGzip(info, level);
    return z;
}

auto withGzip(R)(R r, int level = 6)
{
    return withGzip(r, GzipInfo.init, level);
}


//----------------------------------------------------------------------------//

alias ulong streamsize_t;

private enum StreamFormat
{
    zlib,   // with zlib header and adler32 checksum
    gzip,   // with gzip header and crc32 checksum
    raw,    // without any header nor checksum
}

struct DeflatedOutput(Sink, StreamFormat streamFormat)
{
    private this(Sink sink)
    {
        context_ = new Context;
        sink_    = sink;
    }

    /*
     * manage underlying z_stream object with ref counting
     */
    this(this)
    {
        if (context_)
            ++context_.refs;
    }

    ~this()
    {
        if (context_ && --context_.refs == 0)
            close();
    }


    //--------------------------------------------------------------------//
    // managing stream resources
    //--------------------------------------------------------------------//

    /*
     * Starts compression with the specified compression level and window
     * bits.  This function must never be called if compression is already
     * started.
     */
    private void openRaw(int level, int windowBits)
    in
    {
        assert(context_ != null);
        assert(!context_.opened);
    }
    body
    {
        /* Open the underlying zlib stream. */
        context_.zstream.zalloc = null;
        context_.zstream.zfree  = null;
        context_.zstream.opaque = null;

        const zstat = deflateInit2( &context_.zstream, level,
                Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY );
        switch (zstat)
        {
            case Z_OK:
                break;

            default:
                throw new Exception("deflateInit");
        }

        /* Reset internal states. */
        context_.opened = true;
        context_.size   = 0;
    }

    /**
     * Completes compression and flushes any buffered data to the sink.
     * This function can be called multiple times, and is automatically
     * called when the number of reference to this object becomes zero.
     */
    void close()
    {
        if (!context_.opened)
            return;

        // write any data buffered in the undelying zlib stream
        while (deflateAndWrite(Z_FINISH))
            continue;

        // close the zlib stream
        const stat = deflateEnd(&context_.zstream);
        switch (stat)
        {
            case Z_OK:
                break;

            default:
                throw new Exception("deflateEnd");
        }
        context_.opened = false;

        // write a gzip footer
        static if (streamFormat == StreamFormat.gzip)
            putGzipFooter(sink_, context_.checksum, context_.size);
    }


    // - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - //

    /*
     * Invokes openRaw() with the appropriate configuration for zlib
     * formatted stream.
     */
    static if (streamFormat == StreamFormat.zlib)
    {
        private void openZ(int level)
        {
            openRaw(level, 15); // deflate with zlib header and footer
        }
    }

    /*
     * Invokes openRaw() with the appropriate configuration for gzip
     * formatted  stream.  This function also writes a gzip header.
     */
    static if (streamFormat == StreamFormat.gzip)
    {
        private void openGzip(ref const GzipInfo info, int level)
        {
            openRaw(level, -15); // raw deflate
            context_.checksum = crc32(0, null, 0);
            putGzipHeader(sink_, info);
        }
    }


    //--------------------------------------------------------------------//
    // output range primitive
    //--------------------------------------------------------------------//

    /**
     * Compresses $(D data) as a binary blob and puts the compressed _data
     * onto the sink.
     */
    void put(T, dummy = void)(in T data)
    {
        feed((cast(const(ubyte)*) &data)[0 .. T.sizeof]);
    }

    /// ditto
    void put(T : E[], E)(in T data)
    {
        feed(cast(const(ubyte)[]) data);
    }


    /**
     * Flushes any pending (buffered) data to the sink.
     */
    void flush()
    {
        while (deflateAndWrite(Z_SYNC_FLUSH))
            continue;
    }


    //----------------------------------------------------------------------------//
    // internals
    //----------------------------------------------------------------------------//
private:

    /*
     * Compresses the entire data and writes it to the sink.
     */
    void feed(in ubyte[] data)
    {
        z_stream* zstream = &context_.zstream;

        zstream.next_in  = cast(ubyte*) data.ptr;
        zstream.avail_in = data.length;
        scope(exit) zstream.next_in  = null;
        scope(exit) zstream.avail_in = 0;

        while (zstream.avail_in > 0)
        {
            if (!deflateAndWrite(Z_NO_FLUSH))
                break;
        }

        // update the input checksum and size (for gzip footer)
        static if (streamFormat == StreamFormat.gzip)
        {
            context_.checksum = crc32(context_.checksum, cast(ubyte*)data.ptr, data.length);
            context_.size    += data.length;
        }
    }

    /*
     * Invokes zlib deflate() on the current stream in the spcified mode
     * and writes the result (compressed data) to the sink.
     *
     * Returns:
     *   false if the operation specified by mode is finished.
     */
    bool deflateAndWrite(int mode)
    in
    {
        assert(mode == Z_NO_FLUSH || mode == Z_SYNC_FLUSH || mode == Z_FINISH);
    }
    body
    {
        ubyte[BUFFER_SIZE] buffer  = void;
        z_stream*          zstream = &context_.zstream;
        bool               end;

        // compress to a local buffer
        zstream.next_out  = buffer.ptr;
        zstream.avail_out = buffer.length;

        const stat = deflate(zstream, mode);
        switch (stat)
        {
            case Z_OK:
                break;

            case Z_STREAM_END:
                end = true;
                break;

            case Z_BUF_ERROR:
                if (mode == Z_SYNC_FLUSH)
                    end = true; // nothing to flush
                else
                    throw new Exception("deflate: buf error");
                break;

            default:
                throw new Exception("deflate: unk");
        }

        if (mode == Z_SYNC_FLUSH && zstream.avail_out > 0)
            end = true; // finished flushing

        // write the compressed data if any
        if (size_t size = buffer.length - zstream.avail_out)
            sink_.put(buffer[0 .. size]);

        return !end;
    }


    //--------------------------------------------------------------------//
private:

    // these fields must be shared among all copies of this object
    struct Context
    {
        z_stream     zstream;   // zlib compression stream
        bool         opened;    // true iff the stream is opened
        uint         checksum;  // input checksum
        streamsize_t size;      // total number of bytes compressed
        uint         refs = 1;  // reference counter
    }
    Context*         context_;
    Sink             sink_;     // where compressed data is sent

    enum size_t BUFFER_SIZE = 1024;
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

private enum
{
    ubyte GZ_ID1 = 0x1F,
          GZ_ID2 = 0x8B,

    ubyte GZ_FNAME    = 0b000_01000,
          GZ_COMMENT  = 0b000_10000,
          GZ_RESERVED = 0b111_00000,
}

enum Filesystem : ubyte
{
    unknown = 255,  ///

    FAT = 0,        /// FAT filesystem (MS-DOS, OS/2, NT/Win32)
    Amiga,          /// Amiga
    VMS,            /// VMS (or OpenVMS)
    Unix,           /// Unix
    VM_CMS,         /// VM/CMS
    AtariTOS,       /// Atari TOS
    HPFS,           /// HPFS filesystem (OS/2, NT)
    Macintosh,      /// Macintosh
    Z_System,       /// Z-System
    CP_M,           /// CP/M
    TOPS_20,        /// TOPS-20
    NTFS,           /// NTFS filesystem (NT)
    QDOS,           /// QDOS
    AcornRISCOS,    /// Acorn RISCOS
}

struct GzipInfo
{
    string      name;
    uint        mtime;
    Filesystem  filesystem;
    string      comment;
}

//----------------------------------------------------------------------------//

private void putGzipHeader(Sink)(ref Sink sink, ref const GzipInfo info)
{
    ubyte[10] buf = void;

    ubyte flags = (info.name   .length ? GZ_FNAME   : 0)
                | (info.comment.length ? GZ_COMMENT : 0);
    uint  mtime = info.mtime;

    /* Write out the fixed-length members. */
    buf[0] = GZ_ID1;
    buf[1] = GZ_ID2;
    buf[2] = Z_DEFLATED;
    buf[3] = flags;
    buf[7] = cast(ubyte) (mtime >> 24);
    buf[6] = cast(ubyte) (mtime >> 16);
    buf[5] = cast(ubyte) (mtime >>  8);
    buf[4] = cast(ubyte) (mtime      );
    buf[8] = 0;
    buf[9] = info.filesystem;

    sink.put(buf[0 .. 10]);

    /* Write out filename and comment as zero-terminated strings. */
    if (flags & GZ_FNAME)
    {
        sink.put(cast(const(ubyte)[]) info.name);
        sink.put(buf[0 .. 1] = 0);
    }
    if (flags & GZ_COMMENT)
    {
        sink.put(cast(const(ubyte)[]) info.comment);
        sink.put(buf[0 .. 1] = 0);
    }
}

//----------------------------------------------------------------------------//

private void putGzipFooter(Sink)(ref Sink sink, uint crc, streamsize_t size)
{
    ubyte[8] buf   = void;
    uint     msize = cast(uint) (size & 0xFFFFFFFF);

    buf[3] = cast(ubyte) (crc >> 24);
    buf[2] = cast(ubyte) (crc >> 16);
    buf[1] = cast(ubyte) (crc >>  8);
    buf[0] = cast(ubyte) (crc      );
    buf[7] = cast(ubyte) (msize >> 24);
    buf[6] = cast(ubyte) (msize >> 16);
    buf[5] = cast(ubyte) (msize >>  8);
    buf[4] = cast(ubyte) (msize      );
    sink.put(buf[]);
}


