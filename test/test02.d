// GZIP

import std.array;
import std.range;
import std.stdio;

import etc.c.zlib;


void main()
{
    ubyte[] storage;

    GzipInfo info;
    info.mtime = 0;
    info.fileName = "";
    info.comment = "";
    info.isText = true;
    info.os = GzipOS.unknown;

    auto comp = gzippedOutput(appender(&storage), info);

    foreach (i; 0 .. 16)
        comp.put("天使のブラ ＜ 女神のブラ ＜ 勇者のブラ ＜ 伝説のブラ\n");

    comp.close();

    File("test02-out.gz", "wb").rawWrite(storage);
}


//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://
// output range
//:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::://

auto gzippedOutput(R)(R sink)
    if (isOutputRange!(R, const(ubyte)[]))
{
    return GzipCompressedOutput!(R)(sink, Z_DEFAULT_COMPRESSION);
}

/// ditto
auto gzippedOutput(R)(R sink, int level)
    if (isOutputRange!(R, const(ubyte)[]))
{
    enforce( 1 <= level && level <= 9,
        "Specified an invalid compression level for zlib compression" );
    return GzipCompressedOutput!(R)(sink, level);
}

/// ditto
struct GzipCompressedOutput(R)
{
    private this(R sink, int level)
    in
    {
        assert((1 <= level && level <= 9) || level == Z_DEFAULT_COMPRESSION);
    }
    body
    {
        context_ = new Context;
        context_.sink = sink;
        open(level);
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
        if (context_)
        {
            if (--context_.refs == 0)
                close();
        }
    }


    //--------------------------------------------------------------------//
    // managing stream resource
    //--------------------------------------------------------------------//

    /*
     * Starts compression with the specified compression level.  This
     * function must never be called if compression is already started.
     */
    private void open(int level)
    {
        assert(!context_.opened);
        scope(success) context_.opened = true;

        // Use the default allocator
        context_.zstream.zalloc = null;
        context_.zstream.zfree  = null;
        context_.zstream.opaque = null;

        //immutable rc = deflateInit(&context_.zstream, level);
        immutable rc = deflateInit2(&context_.zstream, level,
                Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY);
        switch (rc)
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
    // compressing data
    //--------------------------------------------------------------------//

    /**
     * Compresses a single object and puts the compressed data onto the
     * sink.
     */
    void put(T)(T value)
        if (!isInputRange!(T))
    {
        feed((cast(ubyte*) &value)[0 .. T.sizeof]);
    }


    /**
     * Compresses the entire elements in source as a binary blob and puts
     * the compressed data onto the sink.  If the source is a range of
     * ranges, the structure is expanded recursively and the 'primitive'
     * ranges are compressed.
     */
    void put(S)(S source)
        if (isInputRange!(S))
    {
        static if (isInputRange!(ElementType!S))
        {
            // The source is a range of ranges.  Compress each range.
            while (!source.empty)
            {
                put(source.front);
                source.popFront;
            }
        }
        else static if (is(S E == E[]))
        {
            // The source is a simple array.  Compress it as a blob.
            feed(cast(const(ubyte)[]) source);
        }
        else static if (ElementType!S.sizeof < BUFFER_SIZE)
        {
            // The source is a general input range.  Copy the contents in
            // a local buffer and compress it.
            alias ElementType!R E;
            ubyte[BUFFER_SIZE] buffer = void;
            size_t             cursor;

            while (!source.empty)
            {
                // Load a chunk of elements
                cursor = 0;
                do
                {
                    cast(Mutable!E*) &buffer[cursor] = source.front;
                    cursor += E.sizeof;
                    data.popFront;
                }
                while (!source.empty && cursor <= buffer.length - E.sizeof);
                // Compress the buffer
                put(buffer[0 .. cursor]);
            }
        }
        else
        {
            // The source produces huge chunks... (unlikely)
            while (!source.empty)
            {
                auto e = source.front;
                feed((cast(ubyte*) &e)[0 .. e.sizeof]);
            }
        }
    }


    //--------------------------------------------------------------------//
    // internal functions
    //--------------------------------------------------------------------//
private:

    /*
     * Compresses the entire data and writes to the sink.
     */
    void feed(in ubyte[] data)
    {
        auto zstream = &context_.zstream;

        zstream.next_in  = cast(ubyte*) data.ptr;   // blame zlib...
        zstream.avail_in = data.length;
        scope(exit) zstream.next_in  = null;        // for GC
        scope(exit) zstream.avail_in = 0;

        while (zstream.avail_in > 0)
        {
            if (!deflateAndWrite(Z_NO_FLUSH))
                break;
        }
    }

    /*
     * Invokes zlib deflate on the current stream with the spcified mode
     * and writes the result to the sink.
     */
    bool deflateAndWrite(int mode)
    {
        ubyte[BUFFER_SIZE] buffer  = void;
        auto               zstream = &context_.zstream;
        bool               atend;

        zstream.next_out  = buffer.ptr;
        zstream.avail_out = buffer.length;
        immutable rc = deflate(zstream, mode);
        switch (rc)
        {
            case Z_OK:
                break;

            case Z_STREAM_END:
                atend = true;
                break;

            default:
                throw new Exception("deflate");
        }

        // Write the compressed data if any
        if (auto size = buffer.length - zstream.avail_out)
        {
            const(ubyte)[] data = buffer[0 .. size];
            context_.sink.put(data);
        }

        return !atend;
    }


    //--------------------------------------------------------------------//
private:

    // z_stream object must never be copied, so hold it by reference.
    struct Context
    {
        z_stream zstream;   // zlib compression stream
        R        sink;      // where compressed data will be sent
        bool     opened;    // true iff the stream is opened
        uint     refs = 1;  // reference counter
    }
    Context* context_;

    // preferred size for temporary buffers
    enum size_t BUFFER_SIZE = 1024;
}


