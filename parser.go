package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// Companies House Product 195/216 snapshot parser.
// Converts fixed-width + chevron-separated appointment data to CSV.
// Field layout matches process_company_appointments_data.py (reference).
//
// Positions are Unicode character offsets (Python text mode). Most rows are
// pure ASCII, so the hot path uses byte indexing; multi-byte rows fall back
// to []rune so field boundaries still match the reference.

const (
	snapshotHeaderIdentifier = "DDDDSNAP"
	trailerRecordIdentifier  = "99999999"
	companyRecordType        = byte('1')
	personRecordType         = byte('2')

	readBufferSize  = 16 * 1024 * 1024
	writeBufferSize = 16 * 1024 * 1024
)

var (
	companiesHeader = []byte("Company Number,Company Status,Number of Officers,Company Name\n")
	personsHeader   = []byte("Company Number,App Date Origin,Appointment Type,Person number,Corporate indicator,Appointment Date,Resignation Date,Person Postcode,Partial Date of Birth,Full Date of Birth,Title,Forenames,Surname,Honours,Care_of,PO_box,Address line 1,Address line 2,Post_town,County,Country,Occupation,Nationality,Resident Country\n")
)

func fastAtoiBytes(b []byte) int {
	n := 0
	for _, c := range b {
		if c >= '0' && c <= '9' {
			n = n*10 + int(c-'0')
		}
	}
	return n
}

func isASCIIBytes(b []byte) bool {
	for _, c := range b {
		if c >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

func clampBytes(b []byte, start, end int) []byte {
	if start < 0 {
		start = 0
	}
	if end > len(b) {
		end = len(b)
	}
	if start >= end {
		return nil
	}
	return b[start:end]
}

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

// csvOut writes CSV rows into a large bufio buffer.
type csvOut struct {
	file *os.File
	bw   *bufio.Writer
	// scratch for integer formatting
	numBuf [12]byte
}

func newCSVOut(path string, header []byte) (*csvOut, error) {
	f, err := os.Create(path)
	if err != nil {
		return nil, err
	}
	bw := bufio.NewWriterSize(f, writeBufferSize)
	if _, err := bw.Write(header); err != nil {
		f.Close()
		return nil, err
	}
	return &csvOut{file: f, bw: bw}, nil
}

func (w *csvOut) writeFieldBytes(s []byte) error {
	needQuote := false
	for _, c := range s {
		if c == ',' || c == '"' || c == '\n' || c == '\r' {
			needQuote = true
			break
		}
	}
	if !needQuote {
		_, err := w.bw.Write(s)
		return err
	}
	if err := w.bw.WriteByte('"'); err != nil {
		return err
	}
	for _, c := range s {
		if c == '"' {
			if _, err := w.bw.WriteString(`""`); err != nil {
				return err
			}
		} else if err := w.bw.WriteByte(c); err != nil {
			return err
		}
	}
	return w.bw.WriteByte('"')
}

func (w *csvOut) writeFieldString(s string) error {
	return w.writeFieldBytes([]byte(s))
}

func (w *csvOut) comma() error  { return w.bw.WriteByte(',') }
func (w *csvOut) newline() error { return w.bw.WriteByte('\n') }

func (w *csvOut) writeInt(n int) error {
	if n == 0 {
		return w.bw.WriteByte('0')
	}
	i := len(w.numBuf)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		w.numBuf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		w.numBuf[i] = '-'
	}
	_, err := w.bw.Write(w.numBuf[i:])
	return err
}

func (w *csvOut) close() error {
	if err := w.bw.Flush(); err != nil {
		w.file.Close()
		return err
	}
	return w.file.Close()
}

func processHeaderRow(row []byte) error {
	if len(row) < 20 || string(row[:8]) != snapshotHeaderIdentifier {
		prefix := row
		if len(prefix) > 8 {
			prefix = prefix[:8]
		}
		return fmt.Errorf("unsupported file type from header: '%s'", prefix)
	}
	fmt.Printf("Processing snapshot file with run number %s from date %s\n", row[8:12], row[12:20])
	return nil
}

func trimRightSpacesBytes(s []byte) []byte {
	i := len(s)
	for i > 0 && s[i-1] == ' ' {
		i--
	}
	return s[:i]
}

// writeCompanyRow parses a company record and writes one CSV line.
func writeCompanyRow(w *csvOut, row []byte) error {
	if isASCIIBytes(row) {
		nameLength := fastAtoiBytes(clampBytes(row, 36, 40))
		name := clampBytes(row, 40, 40+nameLength-1)
		if len(name) > 0 && name[len(name)-1] == ' ' {
			name = trimRightSpacesBytes(name)
		}
		if err := w.writeFieldBytes(clampBytes(row, 0, 8)); err != nil {
			return err
		}
		if err := w.comma(); err != nil {
			return err
		}
		if err := w.writeFieldBytes(clampBytes(row, 9, 10)); err != nil {
			return err
		}
		if err := w.comma(); err != nil {
			return err
		}
		if err := w.writeInt(fastAtoiBytes(clampBytes(row, 32, 36))); err != nil {
			return err
		}
		if err := w.comma(); err != nil {
			return err
		}
		if err := w.writeFieldBytes(name); err != nil {
			return err
		}
		return w.newline()
	}

	r := []rune(string(row))
	nameLength := fastAtoiBytes([]byte(sliceRunes(r, 36, 40)))
	name := sliceRunes(r, 40, 40+nameLength-1)
	if len(name) > 0 && name[len(name)-1] == ' ' {
		name = strings.TrimRight(name, " ")
	}
	if err := w.writeFieldString(sliceRunes(r, 0, 8)); err != nil {
		return err
	}
	if err := w.comma(); err != nil {
		return err
	}
	if err := w.writeFieldString(sliceRunes(r, 9, 10)); err != nil {
		return err
	}
	if err := w.comma(); err != nil {
		return err
	}
	if err := w.writeInt(fastAtoiBytes([]byte(sliceRunes(r, 32, 36)))); err != nil {
		return err
	}
	if err := w.comma(); err != nil {
		return err
	}
	if err := w.writeFieldString(name); err != nil {
		return err
	}
	return w.newline()
}

// writePersonRow parses a person record and writes one CSV line.
// Layout (0-based chars): company[0:8], type[8], origin[9], apptType[10:12],
// personNum[12:24], corp[24], filler[25:32], apptDate[32:40], resign[40:48],
// postcode[48:56], partialDOB[56:64], fullDOB[64:72], varLen[72:76], varData[76:].
func writePersonRow(w *csvOut, row []byte) error {
	var fixed [10][]byte
	var varParts [14][]byte

	if isASCIIBytes(row) {
		fixed[0] = clampBytes(row, 0, 8)
		fixed[1] = clampBytes(row, 9, 10)
		fixed[2] = clampBytes(row, 10, 12)
		fixed[3] = clampBytes(row, 12, 24)
		fixed[4] = clampBytes(row, 24, 25)
		fixed[5] = clampBytes(row, 32, 40)
		fixed[6] = clampBytes(row, 40, 48)
		fixed[7] = clampBytes(row, 48, 56)
		fixed[8] = clampBytes(row, 56, 64)
		fixed[9] = clampBytes(row, 64, 72)
		varLen := fastAtoiBytes(clampBytes(row, 72, 76))
		splitChevronBytes(clampBytes(row, 76, 76+varLen), varParts[:])
	} else {
		r := []rune(string(row))
		fixed[0] = []byte(sliceRunes(r, 0, 8))
		fixed[1] = []byte(sliceRunes(r, 9, 10))
		fixed[2] = []byte(sliceRunes(r, 10, 12))
		fixed[3] = []byte(sliceRunes(r, 12, 24))
		fixed[4] = []byte(sliceRunes(r, 24, 25))
		fixed[5] = []byte(sliceRunes(r, 32, 40))
		fixed[6] = []byte(sliceRunes(r, 40, 48))
		fixed[7] = []byte(sliceRunes(r, 48, 56))
		fixed[8] = []byte(sliceRunes(r, 56, 64))
		fixed[9] = []byte(sliceRunes(r, 64, 72))
		varLen := fastAtoiBytes([]byte(sliceRunes(r, 72, 76)))
		splitChevronBytes([]byte(sliceRunes(r, 76, 76+varLen)), varParts[:])
	}

	for i, f := range fixed {
		if i > 0 {
			if err := w.comma(); err != nil {
				return err
			}
		}
		if err := w.writeFieldBytes(f); err != nil {
			return err
		}
	}
	for _, p := range varParts {
		if err := w.comma(); err != nil {
			return err
		}
		if err := w.writeFieldBytes(p); err != nil {
			return err
		}
	}
	return w.newline()
}

// splitChevronBytes fills dst with up to len(dst) fields from s split on '<'.
func splitChevronBytes(s []byte, dst [][]byte) {
	for i := range dst {
		dst[i] = nil
	}
	if len(s) == 0 {
		return
	}
	start := 0
	idx := 0
	for i := 0; i < len(s) && idx < len(dst); i++ {
		if s[i] == '<' {
			dst[idx] = s[start:i]
			idx++
			start = i + 1
		}
	}
	if idx < len(dst) {
		dst[idx] = s[start:]
	}
}

func processCompanyAppointmentsData(inputFile *os.File, outputFolder, baseInputName string) int {
	companiesFilename := filepath.Join(outputFolder, "companies_data_"+baseInputName+".csv")
	personsFilename := filepath.Join(outputFolder, "persons_data_"+baseInputName+".csv")
	fmt.Printf("Saving companies data to %s\n", companiesFilename)
	fmt.Printf("Saving persons data to %s\n", personsFilename)

	if err := os.MkdirAll(outputFolder, 0755); err != nil {
		fmt.Printf("Error creating output directory: %v\n", err)
		return 1
	}

	companiesOut, err := newCSVOut(companiesFilename, companiesHeader)
	if err != nil {
		fmt.Printf("Error opening companies file: %v\n", err)
		return 1
	}
	personsOut, err := newCSVOut(personsFilename, personsHeader)
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
	rowNum := 0

	for scanner.Scan() {
		row := scanner.Bytes()
		// Scanner reuses the buffer; copy is not needed because we write fields
		// before the next Scan. Trailing CR from CRLF files.
		if n := len(row); n > 0 && row[n-1] == '\r' {
			row = row[:n-1]
		}

		if rowNum == 0 {
			if err := processHeaderRow(row); err != nil {
				fmt.Printf("Error: %v\n", err)
				return 1
			}
			rowNum++
			continue
		}

		if len(row) >= 8 && string(row[:8]) == trailerRecordIdentifier {
			recordCount := fastAtoiBytes(clampBytes(row, 8, 16))
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
			if err := writeCompanyRow(companiesOut, row); err != nil {
				fmt.Printf("Error writing company row: %v\n", err)
				return 1
			}
			companiesProcessed++
		case personRecordType:
			if err := writePersonRow(personsOut, row); err != nil {
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
