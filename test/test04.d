/**
 *
 */
void recursiveCopy(Source, Sink)(Source source, Sink sink)
    if (isInputRange!(Source) && canCopyTo!(Source, Sink))
{
    alias ElementType!Source E;

    static if (isOutputRange!(Sink, E))
    {
        static if (isOutputRange!(Sink, Source) && isArray!(Source))
        {
            sink.put(source);
        }
        else
        {
            foreach (e; source)
                sink.put(e);
        }
    }
    else static if (isInputRange!(E))
    {
        foreach (e; source)
            recursiveCopy(e, sink);
    }
    else static assert(0);
}

template canCopyTo(Source, Sink)
{
    static if (isOutputRange!(Sink, Source))
        enum bool canCopyTo = true;
    else if (isInputRange!(Source))
        enum bool canCopyTo = canCopyTo!(ElementType!E, Sink);
    else
        enum bool canCopyTo = false;
}


/**
 * Puts data as a binary blob.
 *
 * If the data is an input range, the entire elements in the range are put.
 * Nested ranges (range of ranges) are expanded recursively and the 'primitive'
 * ranges are put.
 *
 * Params:
 *   data   = 
 *   putter = 
 */
void putAsBlob(T)(auto ref T data, scope void delegate(in ubyte[]) putter)
{
    enum size_t BUFFER_SIZE = 1024;

    static if (!isInputRange!(T))
    {
        // The data is a simple value.  Write it as-is.
        putter((cast(const(ubyte)*) &data)[0 .. T.sizeof]);
        // TODO: pointers, classes and associative arrays?
    }
    else static if (isInfinite!(T))
    {
        enforce(false, "Attempted to put an infinite input of type " ~ T.stringof);
    }
    else static if (isInputRange!(ElementType!T))
    {
        // The data is a range of ranges.  Expand recursively.
        foreach (e; data)
            putAsBlob(e, putter);
    }
    else static if (is(T E == E[]))
    {
        // The data is a simple array.  Write it as a blob without copying.
        putter(cast(const(ubyte)[]) data);
    }
    else static if (ElementType!T.sizeof <= (BUFFER_SIZE / 4))
    {
        // The data is a general 'flat' input range.  Copy the contents into
        // a local buffer and put the buffer.
        alias ElementType!T E;
        T                  source = data;
        ubyte[BUFFER_SIZE] buffer = void;
        Mutable!E*         cursor = cast(Mutable!E*) buffer.ptr;
        const   E*         guard  = cursor + (buffer.length / E.sizeof);

        while (!source.empty)
        {
            // Load a chunk of elements
            cursor = cast(Mutable!E*) buffer.ptr;
            do
            {
                *cursor++ = source.front;
                source.popFront;
            }
            while (!source.empty && cursor != guard);

            immutable size = cast(size_t) (cursor - buffer.ptr) * E.sizeof;
            assert(size <= buffer.length);
            putter(buffer[0 .. size]);
        }
    }
    else
    {
        // The data is a flat input range producing huge values.
        foreach (e; data)
            putter((cast(ubyte*) &e)[0 .. e.sizeof]);
    }
}

template Mutable(T)
{
         static if (is(T U ==     const)) alias U Mutable;
    else static if (is(T U == immutable)) alias U Mutable;
    else                                  alias T Mutable;
}


