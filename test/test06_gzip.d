
import std.array;
import std.range;


void main()
{
}


//----------------------------------------------------------------------------//

auto withDeflate(R)(R r, int level = 6)
    if (isOutputRange!(R, ubyte[]))
{
    return DeflatedOutput!(R)(r, level);
}

auto withGzip(R)(R r, GzipInfo info, int level = 6)
    if (isOutputRange!(R, ubyte[]))
{
    return DeflatedOutput!(R, StreamFormat.gzip)(r, info, level);
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

struct WithDeflate(Sink)
{
    void put(T : E[], E)(in T data)
    {
        feed(cast(const(ubyte)[]) data);
    }

    void flush()
    {
        ubyte[1024] storage = void;
        ubyte[] dst = storage;

        while (!deflator_.flush(buf))
            sink_.put(storage[0 .. $ - buf.length]);
    }

private:

    void feed(in ubyte[] data)
    {
        ubyte[1024] storage = void;

        const(ubyte)[] input = data;

        while (input.length)
        {
            ubyte[] buf = storage;
            deflator_.filter(input, buf);
            sink_.put(storage[0 .. $ - buf.length]);
        }

        // update input checksum
        checksum_ = zlib.crc32(checksum_, data.ptr, data.length);
    }

private:
    Deflator deflator_;
    Sink     sink_;
    uint     checksum_;
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

private enum StreamFormat
{
    zlib,       // with zlib header and adler32 checksum
    simpleGzip, // with simple gzip header and crc32 checksum
    raw,        // without any header nor checksum
}

struct Deflator
{
    this(int level)
    {
        open(level);
        format_ = StreamFormat.raw;
    }


    //--------------------------------------------------------------------//
    // managing stream resources
    //--------------------------------------------------------------------//

    /*
     * Starts compression with the specified compression level.  This
     * function must never be called if compression is already started.
     */
    private void open(int level)
    in
    {
        assert(!context_.opened);
    }
    body
    {
        scope(success) context_.opened = true;

        context_.zstream.zalloc = null;
        context_.zstream.zfree  = null;
        context_.zstream.opaque = null;

        int windowBits;
        int memLevel = 8;

        final switch (format_)
        {
            case StreamFormat.zlib      : windowBits =  15; break;
            case StreamFormat.simpleGzip: windowBits =  31; break;
            case StreamFormat.raw       : windowBits = -15; break;
        }

        const zstat = deflateInit2( &context_.zstream, level,
                Z_DEFLATED, windowBits, memLevel, Z_DEFAULT_STRATEGY );
        switch (zstat)
        {
            case Z_OK:
                break;

            default:
                throw new Exception("deflateInit");
        }
    }

    /**
     * Completes compression and flushes any buffered data to the sink.
     * This function can be called multiple times.  This function is
     * automatically called when this range object dies.
     */
    void close()
    {
        if (!context_.opened)
            return;
        scope(success) context_.opened = false;

        // write any data buffered in zlib stream
        while (deflateAndWrite(Z_FINISH))
            continue;

        // close the zlib stream
        immutable rc = deflateEnd(&context_.zstream);
        switch (rc)
        {
            case Z_OK:
                break;

            default:
                throw new Exception("deflateEnd");
        }
    }


    //--------------------------------------------------------------------//
    // filter primitives
    //--------------------------------------------------------------------//

    void filter(ref const(ubyte)[] src, ref ubyte[] dst)
    {
        z_stream* zstream = &context_.zstream;

        zstream.next_in  = cast(ubyte*) src.ptr;
        zstream.avail_in = src.length;
        scope(exit) zstream.next_in  = null;
        scope(exit) zstream.avail_in = 0;

        while (zstream.avail_in > 0)
        {
            if (!deflateAndWrite(Z_NO_FLUSH))
                break;
        }
    }

    /*
     * Invokes zlib deflate() on the current stream with the spcified mode
     * and writes the result to the sink.
     */
    bool deflateAndWrite(int mode)
    {
        ubyte[BUFFER_SIZE] buffer  = void;
        z_stream*          zstream = &context_.zstream;
        bool               end;

        zstream.next_out  = buffer.ptr;
        zstream.avail_out = buffer.length;

        switch (deflate(zstream, mode))
        {
            case Z_OK:
                break;

            case Z_STREAM_END:
                end = true;
                break;

            default:
                throw new Exception("deflate");
        }

        // write the compressed data if any
        if (size_t size = buffer.length - zstream.avail_out)
            sink_.put(buffer[0 .. size]);

        return !end;
    }

    bool flush(ref ubyte[] dst)
    {
    }


    //--------------------------------------------------------------------//
private:
    struct Context
    {
        z_stream zstream;   // zlib compression stream
        bool     opened;    // true iff the stream is opened
        uint     refs = 1;  // reference counter
    }
    Context*     context_;

immutable:
    StreamFormat format_;

    enum size_t BUFFER_SIZE = 1024;
}



//----------------------------------------------------------------------------//

private enum StreamFormat
{
    zlib,   // with zlib header and adler32 checksum
    raw,    // without any header nor checksum
}

struct DeflatedOutput(Sink)
{
    private this(Sink sink, StreamFormat format)
    {
        context_ = new Context;
        sink_    = sink;
        format_  = format;
    }

    /*
     * manage a holded z_stream object with ref counting
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
     * Starts compression with the specified compression level.  This
     * function must never be called if compression is already started.
     */
    private void open(int level)
    in
    {
        assert(!context_.opened);
    }
    body
    {
        scope(success) context_.opened = true;

        context_.zstream.zalloc = null;
        context_.zstream.zfree  = null;
        context_.zstream.opaque = null;

        int windowBits;
        int memLevel = 8;

        final switch (format_)
        {
            case StreamFormat.zlib: windowBits =  15; break;
            case StreamFormat.raw : windowBits = -15; break;
        }

        const zstat = deflateInit2( &context_.zstream, level,
                Z_DEFLATED, windowBits, memLevel, Z_DEFAULT_STRATEGY );
        switch (zstat)
        {
            case Z_OK:
                break;

            default:
                throw new Exception("deflateInit");
        }
    }

    /**
     * Completes compression and flushes any buffered data to the sink.
     * This function can be called multiple times.  This function is
     * automatically called when this range object dies.
     */
    void close()
    {
        if (!context_.opened)
            return;
        scope(success) context_.opened = false;

        // write any data buffered in zlib stream
        while (deflateAndWrite(Z_FINISH))
            continue;

        // close the zlib stream
        immutable rc = deflateEnd(&context_.zstream);
        switch (rc)
        {
            case Z_OK:
                break;

            default:
                throw new Exception("deflateEnd");
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
     *
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
     * Compresses the entire data and writes to the sink.
     */
    void feed(in ubyte[] data)
    {
        auto zstream = &context_.zstream;

        zstream.next_in  = cast(ubyte*) data.ptr;   // blame zlib...
        zstream.avail_in = data.length;
        scope(exit) zstream.next_in  = null;
        scope(exit) zstream.avail_in = 0;

        while (zstream.avail_in > 0)
        {
            if (!deflateAndWrite(Z_NO_FLUSH))
                break;
        }
    }

    /*
     * Invokes zlib deflate() on the current stream with the spcified mode
     * and writes the result to the sink.
     */
    bool deflateAndWrite(int mode)
    {
        ubyte[BUFFER_SIZE] buffer  = void;
        z_stream*          zstream = &context_.zstream;
        bool               end;

        zstream.next_out  = buffer.ptr;
        zstream.avail_out = buffer.length;

        switch (deflate(zstream, mode))
        {
            case Z_OK:
                break;

            case Z_STREAM_END:
                end = true;
                break;

            default:
                throw new Exception("deflate");
        }

        // write the compressed data if any
        if (size_t size = buffer.length - zstream.avail_out)
            sink_.put(buffer[0 .. size]);

        return !end;
    }


    //--------------------------------------------------------------------//
private:
    struct Context
    {
        z_stream zstream;   // zlib compression stream
        bool     opened;    // true iff the stream is opened
        uint     refs = 1;  // reference counter
    }
    Context*     context_;
    Sink         sink_;     // where compressed data is sent

immutable:
    StreamFormat format_;

    enum size_t BUFFER_SIZE = 1024;
}


//----------------------------------------------------------------------------//

struct GzippedOutput(Sink)
    if (isOutputRange!(Sink, ubyte[]))
{



    void writeGzipHeader(GzipInfo info)
    {
        ubyte[10] buf = void;

        ubyte flags =
              (info.name   .length ? GZ_FNAME   : 0)
            | (info.comment.length ? GZ_COMMENT : 0);

        /* Write out the fixed-length members. */
        buf[0] = GZ_ID1;
        buf[1] = GZ_ID2;
        buf[2] = Z_DEFLATED;
        buf[3] = flags;
        buf[4] = cast(ubyte) (info.mtime >> 24);
        buf[5] = cast(ubyte) (info.mtime >> 16);
        buf[6] = cast(ubyte) (info.mtime >>  8);
        buf[7] = cast(ubyte) (info.mtime      );
        buf[8] = 0;
        buf[9] = info.filesystem;

        sink_.put(buf[0 .. 10]);

        /* Write out filename and comment as zero-terminated strings. */
        if (flags & GZ_FNAME)
        {
            sink_.put(cast(const(ubyte)[]) info.name);
            sink_.put(buf[0 .. 1] = 0);
        }
        if (flags & GZ_COMMENT)
        {
            sink_.put(cast(const(ubyte)[]) info.comment);
            sink_.put(buf[0 .. 1] = 0);
        }
    }

private:
    DeflatedOutput!(Sink) forward_;
}


private
{
    enum ubyte GZ_ID1 = 0x1F,
               GZ_ID2 = 0x8B;
    enum ubyte GZ_FNAME    = 0b000_01000,
               GZ_COMMENT  = 0b000_10000,
               GZ_RESERVED = 0b111_00000;
}

struct GzipInfo
{
    string      name;
//  Date        mtime;
    uint        mtime;
    Filesystem  filesystem;
    string      comment;
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
