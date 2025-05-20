package main

import (
	"bufio"
	"crypto/md5"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type ProgressWriter struct {
	io.Writer
	Total      int64
	Downloaded int64
	Filename   string
}

func (pw *ProgressWriter) Write(p []byte) (int, error) {
	n, err := pw.Writer.Write(p)
	pw.Downloaded += int64(n)
	percentage := float64(pw.Downloaded) / float64(pw.Total) * 100
	fmt.Printf("\r%s: %.2f%% (%d/%d bytes)    ",
		shortenFilename(pw.Filename), percentage, pw.Downloaded, pw.Total)
	return n, err
}

func shortenFilename(filename string) string {
	if len(filename) > 40 {
		return filename[:18] + "..." + filename[len(filename)-18:]
	}
	return filename
}

func getTempDirName(url string) string {
	hash := md5.Sum([]byte(url))
	return fmt.Sprintf("download_%x", hash)
}

func getSafeFilename(urlStr string) string {
	parsedURL, err := url.Parse(urlStr)
	if err != nil {
		hash := md5.Sum([]byte(urlStr))
		return fmt.Sprintf("download_%x", hash)
	}

	filename := filepath.Base(parsedURL.Path)

	decodedFilename, err := url.QueryUnescape(filename)
	if err != nil {
		decodedFilename = strings.ReplaceAll(filename, "%20", " ")
	}

	safeFilename := strings.Map(func(r rune) rune {
		if strings.ContainsRune(`<>:"/\|?*`, r) {
			return '_'
		}
		return r
	}, decodedFilename)

	if safeFilename == "" || safeFilename == "." {
		hash := md5.Sum([]byte(urlStr))
		return fmt.Sprintf("download_%x", hash)
	}

	return safeFilename
}

func downloadFile(url string, filepath string, concurrency int) error {
	tempDirName := getTempDirName(url)
	dir := fmt.Sprintf(".%s.chunks", tempDirName)

	err := os.MkdirAll(dir, 0755)
	if err != nil {
		return err
	}

	resp, err := http.Head(url)
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("bad status: %s", resp.Status)
	}

	fileSize, err := strconv.ParseInt(resp.Header.Get("Content-Length"), 10, 64)
	if err != nil {
		return fmt.Errorf("failed to parse Content-Length: %v", err)
	}

	metaFile, err := os.OpenFile(dir+"/metadata", os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return err
	}
	defer metaFile.Close()

	var downloadedChunks map[int]bool = make(map[int]bool)
	scanner := bufio.NewScanner(metaFile)
	for scanner.Scan() {
		chunkID, err := strconv.Atoi(scanner.Text())
		if err == nil {
			downloadedChunks[chunkID] = true
		}
	}

	chunkSize := fileSize / int64(concurrency)
	if chunkSize < 1024*1024 { // Minimum 1MB chunk
		chunkSize = 1024 * 1024
		if fileSize < chunkSize {
			chunkSize = fileSize
		}
	}

	numChunks := int((fileSize + chunkSize - 1) / chunkSize)
	if numChunks > concurrency {
		numChunks = concurrency
	}

	fmt.Printf("Downloading %s (%.2f MB) using %d chunks\n",
		filepath, float64(fileSize)/(1024*1024), numChunks)

	var wg sync.WaitGroup
	var mutex sync.Mutex
	totalDownloaded := int64(0)

	for i := 0; i < numChunks; i++ {
		if downloadedChunks[i] {
			start := int64(i) * chunkSize
			end := start + chunkSize - 1
			if end >= fileSize {
				end = fileSize - 1
			}
			chunkBytes := end - start + 1
			totalDownloaded += chunkBytes
			continue
		}

		wg.Add(1)
		go func(chunkID int) {
			defer wg.Done()

			start := int64(chunkID) * chunkSize
			end := start + chunkSize - 1
			if end >= fileSize {
				end = fileSize - 1
			}

			chunkFileName := fmt.Sprintf("%s/chunk%d", dir, chunkID)
			chunkFile, err := os.Create(chunkFileName)
			if err != nil {
				fmt.Printf("Error creating chunk file %s: %v\n", chunkFileName, err)
				return
			}
			defer chunkFile.Close()

			req, err := http.NewRequest("GET", url, nil)
			if err != nil {
				fmt.Printf("Error creating request for chunk %d: %v\n", chunkID, err)
				return
			}
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))

			client := &http.Client{
				Timeout: 30 * time.Minute, // Increase timeout for large files
			}
			resp, err := client.Do(req)
			if err != nil {
				fmt.Printf("Error downloading chunk %d: %v\n", chunkID, err)
				return
			}
			defer resp.Body.Close()

			if resp.StatusCode != http.StatusPartialContent && resp.StatusCode != http.StatusOK {
				fmt.Printf("Error: bad status for chunk %d: %s\n", chunkID, resp.Status)
				return
			}

			chunkWriter := &ProgressWriter{
				Writer:     chunkFile,
				Total:      end - start + 1,
				Filename:   filepath,
				Downloaded: 0,
			}
			bytesWritten, err := io.Copy(chunkWriter, resp.Body)
			if err != nil {
				fmt.Printf("Error writing chunk %d: %v\n", chunkID, err)
				return
			}

			mutex.Lock()
			totalDownloaded += bytesWritten
			metaFile.WriteString(fmt.Sprintf("%d\n", chunkID))
			mutex.Unlock()

			fmt.Printf("\rDownloaded chunk %d (%d bytes)    \n", chunkID, bytesWritten)
		}(i)
	}

	wg.Wait()

	if totalDownloaded < fileSize {
		return fmt.Errorf("download incomplete: %d/%d bytes", totalDownloaded, fileSize)
	}

	fmt.Println("Merging chunks...")
	finalFile, err := os.Create(filepath)
	if err != nil {
		return err
	}
	defer finalFile.Close()

	for i := 0; i < numChunks; i++ {
		chunkFileName := fmt.Sprintf("%s/chunk%d", dir, i)
		chunkFile, err := os.Open(chunkFileName)
		if err != nil {
			return err
		}

		_, err = io.Copy(finalFile, chunkFile)
		chunkFile.Close()
		if err != nil {
			return err
		}
	}

	os.RemoveAll(dir)
	fmt.Printf("Download completed: %s (%.2f MB)\n", filepath, float64(fileSize)/(1024*1024))
	return nil
}

func main() {
	urlFile := flag.String("file", "", "file containing URLs to download")
	outputDir := flag.String("dir", "downloads", "directory to save downloads")
	concurrency := flag.Int("n", 4, "number of concurrent downloads")
	chunkConcurrency := flag.Int("c", 4, "number of chunks per download")
	startFrom := flag.Int("start", 0, "start from this line (skip earlier lines)")
	retries := flag.Int("retries", 3, "number of retry attempts for failed downloads")
	flag.Parse()

	if *urlFile == "" {
		fmt.Println("Please specify a file containing URLs with -file")
		flag.PrintDefaults()
		return
	}

	err := os.MkdirAll(*outputDir, 0755)
	if err != nil {
		fmt.Printf("Error creating output directory: %v\n", err)
		return
	}

	file, err := os.Open(*urlFile)
	if err != nil {
		fmt.Printf("Error opening URL file: %v\n", err)
		return
	}
	defer file.Close()

	sem := make(chan struct{}, *concurrency)
	var wg sync.WaitGroup

	scanner := bufio.NewScanner(file)
	lineNum := 0
	for scanner.Scan() {
		url := scanner.Text()
		lineNum++

		if lineNum < *startFrom {
			continue
		}

		filename := getSafeFilename(url)

		fullPath := filepath.Join(*outputDir, filename)

		if _, err := os.Stat(fullPath); err == nil {
			fmt.Printf("Skipping %s (already exists)\n", fullPath)
			continue
		}

		wg.Add(1)
		sem <- struct{}{} // Acquire semaphore
		go func(url, path string, line int) {
			defer wg.Done()
			defer func() { <-sem }() // Release semaphore

			fmt.Printf("Starting download [%d]: %s\n", line, path)
			start := time.Now()

			var downloadErr error
			for attempt := 0; attempt < *retries; attempt++ {
				if attempt > 0 {
					fmt.Printf("Retry %d/%d for %s\n", attempt, *retries, path)
					time.Sleep(time.Duration(attempt) * 2 * time.Second) // Exponential backoff
				}

				downloadErr = downloadFile(url, path, *chunkConcurrency)
				if downloadErr == nil {
					break // Download succeeded
				}

				fmt.Printf("Error on attempt %d: %v\n", attempt+1, downloadErr)
			}

			if downloadErr != nil {
				fmt.Printf("Failed to download after %d attempts: %s - %v\n",
					*retries, url, downloadErr)
				return
			}

			elapsed := time.Since(start)
			fmt.Printf("Completed download [%d]: %s (took %s)\n", line, path, elapsed)
		}(url, fullPath, lineNum)
	}

	wg.Wait()
	fmt.Println("All downloads completed!")
}
