package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Companies House Product 195/216 snapshot parser.
// Converts fixed-width + chevron-separated appointment data to CSV.
// Field layout matches process_company_appointments_data.py (reference).

const (
	snapshotHeaderIdentifier = "DDDDSNAP"
	trailerRecordIdentifier  = "99999999"
	companyRecordType        = '1'
	personRecordType         = '2'

	// Large buffers: input is sequential read; output is sequential write.
	// 4–16 MiB keeps syscall overhead low without ballooning RSS.
	readBufferSize  = 8 * 1024 * 1024
	writeBufferSize = 4 * 1024 * 1024
	batchSize       = 30000
)

var (
	companiesHeader = []string{
		"Company Number", "Company Status", "Number of Officers", "Company Name",
	}
	personsHeader = []string{
		"Company Number", "App Date Origin", "Appointment Type", "Person number",
		"Corporate indicator", "Appointment Date", "Resignation Date", "Person Postcode",
		"Partial Date of Birth", "Full Date of Birth", "Title", "Forenames", "Surname",
		"Honours", "Care_of", "PO_box", "Address line 1", "Address line 2", "Post_town",
		"County", "Country", "Occupation", "Nationality", "Resident Country",
	}
)

func fastAtoi(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= '0' && c <= '9' {
			n = n*10 + int(c-'0')
		}
	}
	return n
}

// needsCSVQuote reports whether s must be quoted under standard CSV rules.
func needsCSVQuote(s string) bool {
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case ',', '"', '\n', '\r':
			return true
		}
	}
	return false
}

// writeCSVField writes one CSV field (optionally quoted) into b.
func writeCSVField(b *strings.Builder, s string) {
	if needsCSVQuote(s) {
		b.WriteByte('"')
		for i := 0; i < len(s); i++ {
			if s[i] == '"' {
				b.WriteString(`""`)
			} else {
				b.WriteByte(s[i])
			}
		}
		b.WriteByte('"')
		return
	}
	b.WriteString(s)
}

func writeCSVRow(b *strings.Builder, fields []string) {
	for i, f := range fields {
		if i > 0 {
			b.WriteByte(',')
		}
		writeCSVField(b, f)
	}
	b.WriteByte('\n')
}

func processHeaderRow(row string) error {
	if len(row) < 20 || !strings.HasPrefix(row, snapshotHeaderIdentifier) {
		prefix := row
		if len(prefix) > 8 {
			prefix = prefix[:8]
		}
		return fmt.Errorf("unsupported file type from header: '%s'", prefix)
	}
	fmt.Printf("Processing snapshot file with run number %s from date %s\n", row[8:12], row[12:20])
	return nil
}

// sliceRunes returns string(r[start:end]) with bounds clamping.
func sliceRunes(r []rune, start, end int) string {
	if start < 0 {
		start = 0
	}
	if end > len(r) {
		end = len(r)
	}
	if start >= end {
		return ""
	}
	return string(r[start:end])
}

// processCompanyRow extracts company fields matching the Python reference.
// All field positions are Unicode character offsets (Python text indexing).
// Company name length includes the trailing '<' delimiter.
func processCompanyRow(row string, out []string) []string {
	if cap(out) < 4 {
		out = make([]string, 4)
	} else {
		out = out[:4]
	}
	r := []rune(row)
	nameLength := fastAtoi(sliceRunes(r, 36, 40))
	// Length includes trailing '<'; take name_length-1 characters from col 40.
	companyName := sliceRunes(r, 40, 40+nameLength-1)
	if len(companyName) > 0 && companyName[len(companyName)-1] == ' ' {
		companyName = strings.TrimRight(companyName, " ")
	}
	out[0] = sliceRunes(r, 0, 8)
	out[1] = sliceRunes(r, 9, 10)
	// Python writes number_of_officers as int (no zero padding).
	out[2] = itoa(fastAtoi(sliceRunes(r, 32, 36)))
	out[3] = companyName
	return out
}

// processPersonRow extracts person fields matching the Python reference.
// Positions are Unicode character offsets (not UTF-8 bytes): multi-byte
// characters in postcodes/names shift later fields the same way Python does.
// Layout (0-based): company[0:8], type[8], origin[9], apptType[10:12],
// personNum[12:24], corp[24], filler[25:32], apptDate[32:40], resign[40:48],
// postcode[48:56], partialDOB[56:64], fullDOB[64:72], varLen[72:76], varData[76:].
func processPersonRow(row string, out []string) []string {
	if cap(out) < 24 {
		out = make([]string, 24)
	} else {
		out = out[:24]
	}

	r := []rune(row)
	varLen := fastAtoi(sliceRunes(r, 72, 76))
	variableData := sliceRunes(r, 76, 76+varLen)

	// Split on '<' without trimming — empty fields are consecutive chevrons.
	// Python: parts = variable_data.split('<') then parts[0]..parts[13].
	var parts [14]string
	if variableData != "" {
		start := 0
		idx := 0
		for i := 0; i < len(variableData) && idx < 14; i++ {
			if variableData[i] == '<' {
				parts[idx] = variableData[start:i]
				idx++
				start = i + 1
			}
		}
		if idx < 14 {
			parts[idx] = variableData[start:]
		}
	}

	out[0] = sliceRunes(r, 0, 8)
	out[1] = sliceRunes(r, 9, 10)
	out[2] = sliceRunes(r, 10, 12)
	out[3] = sliceRunes(r, 12, 24)
	out[4] = sliceRunes(r, 24, 25)
	out[5] = sliceRunes(r, 32, 40)
	out[6] = sliceRunes(r, 40, 48)
	out[7] = sliceRunes(r, 48, 56)
	out[8] = sliceRunes(r, 56, 64)
	out[9] = sliceRunes(r, 64, 72)
	for i := 0; i < 14; i++ {
		out[10+i] = parts[i]
	}
	return out
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var buf [12]byte
	i := len(buf)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}

// csvBatchWriter keeps one file open and flushes rows in batches.
type csvBatchWriter struct {
	file   *os.File
	bw     *bufio.Writer
	batch  strings.Builder
	count  int
	fields []string // scratch for one row
}

func newCSVBatchWriter(path string, header []string) (*csvBatchWriter, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	w := &csvBatchWriter{
		file:   f,
		bw:     bufio.NewWriterSize(f, writeBufferSize),
		fields: make([]string, 0, 24),
	}
	w.batch.Grow(batchSize * 128)
	writeCSVRow(&w.batch, header)
	if _, err := w.bw.WriteString(w.batch.String()); err != nil {
		f.Close()
		return nil, err
	}
	w.batch.Reset()
	return w, nil
}

func (w *csvBatchWriter) writeRow(fields []string) error {
	writeCSVRow(&w.batch, fields)
	w.count++
	if w.count >= batchSize {
		return w.flushBatch()
	}
	return nil
}

func (w *csvBatchWriter) flushBatch() error {
	if w.batch.Len() == 0 {
		return nil
	}
	if _, err := w.bw.WriteString(w.batch.String()); err != nil {
		return err
	}
	w.batch.Reset()
	w.count = 0
	return nil
}

func (w *csvBatchWriter) close() error {
	if err := w.flushBatch(); err != nil {
		w.file.Close()
		return err
	}
	if err := w.bw.Flush(); err != nil {
		w.file.Close()
		return err
	}
	return w.file.Close()
}

func processCompanyAppointmentsData(inputFile *os.File, outputFolder, baseInputName string) int {
	companiesFilename := filepath.Join(outputFolder, fmt.Sprintf("companies_data_%s.csv", baseInputName))
	personsFilename := filepath.Join(outputFolder, fmt.Sprintf("persons_data_%s.csv", baseInputName))
	fmt.Printf("Saving companies data to %s\n", companiesFilename)
	fmt.Printf("Saving persons data to %s\n", personsFilename)

	if err := os.MkdirAll(outputFolder, 0755); err != nil {
		fmt.Printf("Error creating output directory: %v\n", err)
		return 1
	}

	companiesOut, err := newCSVBatchWriter(companiesFilename, companiesHeader)
	if err != nil {
		fmt.Printf("Error opening companies file: %v\n", err)
		return 1
	}
	personsOut, err := newCSVBatchWriter(personsFilename, personsHeader)
	if err != nil {
		companiesOut.close()
		fmt.Printf("Error opening persons file: %v\n", err)
		return 1
	}
	defer companiesOut.close()
	defer personsOut.close()

	scanner := bufio.NewScanner(inputFile)
	scanner.Buffer(make([]byte, readBufferSize), readBufferSize*2)

	companiesProcessed := 0
	personsProcessed := 0
	companyFields := make([]string, 4)
	personFields := make([]string, 24)

	rowNum := 0
	for scanner.Scan() {
		row := scanner.Text()
		// Strip trailing CR if present (Windows-style lines in a text open).
		if len(row) > 0 && row[len(row)-1] == '\r' {
			row = row[:len(row)-1]
		}

		if rowNum == 0 {
			if err := processHeaderRow(row); err != nil {
				fmt.Printf("Error: %v\n", err)
				return 1
			}
			rowNum++
			continue
		}

		if strings.HasPrefix(row, trailerRecordIdentifier) {
			if err := companiesOut.flushBatch(); err != nil {
				fmt.Printf("Error writing companies: %v\n", err)
				return 1
			}
			if err := personsOut.flushBatch(); err != nil {
				fmt.Printf("Error writing persons: %v\n", err)
				return 1
			}
			recordCount := fastAtoi(row[8:16])
			totalProcessed := companiesProcessed + personsProcessed
			if recordCount != totalProcessed {
				fmt.Printf("ERROR: Processed %d records out of %d\n", totalProcessed, recordCount)
				return 1
			}
			fmt.Printf("Processed %d records: %d companies, %d persons.\n", totalProcessed, companiesProcessed, personsProcessed)
			return 0
		}

		if len(row) <= 8 {
			rowNum++
			continue
		}

		switch row[8] {
		case companyRecordType:
			companyFields = processCompanyRow(row, companyFields)
			if err := companiesOut.writeRow(companyFields); err != nil {
				fmt.Printf("Error writing company row: %v\n", err)
				return 1
			}
			companiesProcessed++
		case personRecordType:
			personFields = processPersonRow(row, personFields)
			if err := personsOut.writeRow(personFields); err != nil {
				fmt.Printf("Error writing person row: %v\n", err)
				return 1
			}
			personsProcessed++
		}
		rowNum++
	}

	if err := scanner.Err(); err != nil {
		fmt.Printf("Error reading file: %v\n", err)
		return 1
	}

	fmt.Println("ERROR: No trailer record found.")
	return 1
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: ./parser input_file output_folder")
		os.Exit(1)
	}

	inputFilename := os.Args[1]
	outputFolder := os.Args[2]

	inputFile, err := os.Open(inputFilename)
	if err != nil {
		fmt.Printf("Error opening input file: %v\n", err)
		os.Exit(1)
	}
	defer inputFile.Close()

	baseInputName := strings.TrimSuffix(filepath.Base(inputFilename), filepath.Ext(inputFilename))
	os.Exit(processCompanyAppointmentsData(inputFile, outputFolder, baseInputName))
}
