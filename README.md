# Libgen URL Parser & Downloader

This repo contains two tools that work together to help you (bulk)download books from Library Genesis ( http://libgen.is/ ):

1. `parser` - extracts download URLs from Libgen SQL dumps
2. `downloader` - downloads files from those URLs

These binaries are compiled on Debian with glibc. 
Recommended to build them yourself from source, see below.

## Building the Parser

```bash
# Install Zig (if you don't have it)
wget https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz
tar -xf zig-linux-x86_64-0.12.0.tar.xz
export PATH=$PATH:$PWD/zig-linux-x86_64-0.12.0

# Build it
zig build-exe parser.zig
```

## Using the Parser

The parser reads a Libgen SQL dump and outputs download URLs:

```bash
./parser libgen_compact.sql links.txt
```

It'll show progress as it runs through the file and generates URLs like:
`https://download.books.ms/main/11000/29c764a1af51f8f9ebfd721a6eac4a7b/Filaseta%20M.%20-%20Algebraic%20number%20theory%20%28Math%20784%29%20%281996%29.pdf`

## Building the Downloader

```bash
# Install Go (if you don't have it)
# Then build the downloader
go build downloader.go
```

## Using the Downloader

```bash
./downloader -file=urls.txt -dir=books -n=4 -c=8
```

Where:
- `-file` points to the URL list from the parser
- `-dir` is where books should be saved (will be created if needed)
- `-n` is how many books to download at once (4 is good for most connections)
- `-c` is how many chunks to split each download into (try 8 for faster downloads)

If your download gets interrupted, just run the command again - it'll pick up where it left off

## Notice

- If your download gets stuck, use `Ctrl+C` to stop it, then run with `-start=123` to resume from line 123
- For slower connections, reduce `-n` to 2 and `-c` to 4
- For fast connections `-n=8 -c=16`
- Downloads are automatically resumed if they get interrupted

## Issues

- "segmentation fault" from parser? You might be low on RAM, close other apps
- "error downloading" from downloader? Check your internet or try with more `-retries`
- Weird filenames? The downloader handles URL-encoding/special chars automatically
