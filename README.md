# Fixed width parser for companies house data

Companies House publish bulk data products in a custom file format which is broadly fixed width + variable width chevron separated values.

Files have a custom header and trailer format with metadata.

Files are encoded as plain text - no binary.

Most data products are split into multiple files to allow parallel processing.

## Parser rules

A parser for this format should convert the data into a common, interoperable format like CSV, which can be read by tools like DuckDB.

A parser implementation MUST correctly convert an input file to valid data file(s), consistently and deterministically. All input data must be represented in the output - no data rows can be lost (this does not include metadata such as number of lines in a file). 

The output can be compressed (zstd/gzip), if by doing so the processing is sped up by reduce disk usage on output.

Assuming perfect correctness is achieved, a parser should aim to be high performance and efficient to achieve fast conversion times.

The input to a parser implementation is a file path pointing to a single data file on disk, and a file path to an output directory where output files are to be written.

The parser must read the input data file, and incrementally parse (in a streaming fashion) all records and write them to the appropriate output file(s).
At no point should the parser load the entire data set into memory. It MUST allow for larger than memory processing.
A single input file may result in multiple output files - the general rule for this is one entity type per output file, eg officers in one file, companies in another. But variants of an entity type, eg corporate officer and natural officer can be in the same file provided most of the fields are the same.

A parser may make full use of available resources on the machine its running on - including all CPU cores.
