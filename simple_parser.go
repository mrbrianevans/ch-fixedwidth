// simple_parser.go — readable Companies House snapshot parser (Prod 195/216).
//
// Optimised for clarity, not speed. Output matches process_company_appointments_data.py
// and the faster parser.go.
//
// Usage:
//
//	go run simple_parser.go <input.dat> <output_folder>
//
// Input files are UTF-8. Field positions are Unicode character offsets (same as
// Python text indexing), not raw byte offsets — important for names/postcodes
// with accents.
package main

import (
	"bufio"
	"encoding/csv"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	snapshotHeader = "DDDDSNAP"
	trailerID      = "99999999"
	companyType    = '1'
	personType     = '2'
)

var companiesHeader = []string{
	"Company Number", "Company Status", "Number of Officers", "Company Name",
}

var personsHeader = []string{
	"Company Number", "App Date Origin", "Appointment Type", "Person number",
	"Corporate indicator", "Appointment Date", "Resignation Date", "Person Postcode",
	"Partial Date of Birth", "Full Date of Birth", "Title", "Forenames", "Surname",
	"Honours", "Care_of", "PO_box", "Address line 1", "Address line 2", "Post_town",
	"County", "Country", "Occupation", "Nationality", "Resident Country",
}

func main() {
	if len(os.Args) < 3 {
		fmt.Println("Usage: go run simple_parser.go <input_file> <output_folder>")
		os.Exit(1)
	}

	inputPath := os.Args[1]
	outputDir := os.Args[2]
	baseName := strings.TrimSuffix(filepath.Base(inputPath), filepath.Ext(inputPath))

	in, err := os.Open(inputPath)
	if err != nil {
		fmt.Printf("Error opening input: %v\n", err)
		os.Exit(1)
	}
	defer in.Close()

	if err := os.MkdirAll(outputDir, 0755); err != nil {
		fmt.Printf("Error creating output directory: %v\n", err)
		os.Exit(1)
	}

	os.Exit(parseSnapshot(in, outputDir, baseName))
}

func parseSnapshot(in *os.File, outputDir, baseName string) int {
	companiesPath := filepath.Join(outputDir, "companies_data_"+baseName+".csv")
	personsPath := filepath.Join(outputDir, "persons_data_"+baseName+".csv")
	fmt.Printf("Saving companies data to %s\n", companiesPath)
	fmt.Printf("Saving persons data to %s\n", personsPath)

	companiesFile, err := os.Create(companiesPath)
	if err != nil {
		fmt.Printf("Error creating companies file: %v\n", err)
		return 1
	}
	defer companiesFile.Close()

	personsFile, err := os.Create(personsPath)
	if err != nil {
		fmt.Printf("Error creating persons file: %v\n", err)
		return 1
	}
	defer personsFile.Close()

	companiesCSV := csv.NewWriter(companiesFile)
	personsCSV := csv.NewWriter(personsFile)
	defer companiesCSV.Flush()
	defer personsCSV.Flush()

	if err := companiesCSV.Write(companiesHeader); err != nil {
		fmt.Printf("Error writing companies header: %v\n", err)
		return 1
	}
	if err := personsCSV.Write(personsHeader); err != nil {
		fmt.Printf("Error writing persons header: %v\n", err)
		return 1
	}

	scanner := bufio.NewScanner(in)
	// Records can be long (person max ~1KB); allow large lines.
	scanner.Buffer(make([]byte, 1024*1024), 2*1024*1024)

	companiesN, personsN := 0, 0
	lineNo := 0

	for scanner.Scan() {
		// Decode as UTF-8 runes so slicing matches Python character indices.
		line := strings.TrimRight(scanner.Text(), "\r")
		chars := []rune(line)

		if lineNo == 0 {
			if err := checkHeader(chars); err != nil {
				fmt.Printf("Error: %v\n", err)
				return 1
			}
			lineNo++
			continue
		}

		if charString(chars, 0, 8) == trailerID {
			companiesCSV.Flush()
			personsCSV.Flush()
			expected, _ := strconv.Atoi(strings.TrimSpace(charString(chars, 8, 16)))
			got := companiesN + personsN
			if expected != got {
				fmt.Printf("ERROR: Processed %d records out of %d\n", got, expected)
				return 1
			}
			fmt.Printf("Processed %d records: %d companies, %d persons.\n", got, companiesN, personsN)
			return 0
		}

		if len(chars) <= 8 {
			lineNo++
			continue
		}

		switch chars[8] {
		case companyType:
			row, err := parseCompany(chars)
			if err != nil {
				fmt.Printf("Error parsing company on line %d: %v\n", lineNo+1, err)
				return 1
			}
			if err := companiesCSV.Write(row); err != nil {
				fmt.Printf("Error writing company row: %v\n", err)
				return 1
			}
			companiesN++
		case personType:
			row, err := parsePerson(chars)
			if err != nil {
				fmt.Printf("Error parsing person on line %d: %v\n", lineNo+1, err)
				return 1
			}
			if err := personsCSV.Write(row); err != nil {
				fmt.Printf("Error writing person row: %v\n", err)
				return 1
			}
			personsN++
		}

		lineNo++
	}

	if err := scanner.Err(); err != nil {
		fmt.Printf("Error reading input: %v\n", err)
		return 1
	}

	fmt.Println("ERROR: No trailer record found.")
	return 1
}

func checkHeader(chars []rune) error {
	if charString(chars, 0, 8) != snapshotHeader {
		return fmt.Errorf("unsupported file type from header: '%s'", charString(chars, 0, 8))
	}
	fmt.Printf("Processing snapshot file with run number %s from date %s\n",
		charString(chars, 8, 12), charString(chars, 12, 20))
	return nil
}

// parseCompany — company record layout (0-based character positions):
//
//	[0:8]   company number
//	[8]     record type '1'
//	[9]     company status
//	[32:36] number of officers
//	[36:40] company name length (includes trailing '<')
//	[40:]   company name (length-1 chars; the '<' is not part of the name)
func parseCompany(chars []rune) ([]string, error) {
	nameLen, err := atoiField(charString(chars, 36, 40))
	if err != nil {
		return nil, fmt.Errorf("name length: %w", err)
	}
	name := charString(chars, 40, 40+nameLen-1)
	if strings.HasSuffix(name, " ") {
		name = strings.TrimRight(name, " ")
	}

	officers, err := atoiField(charString(chars, 32, 36))
	if err != nil {
		return nil, fmt.Errorf("officer count: %w", err)
	}

	return []string{
		charString(chars, 0, 8),
		charString(chars, 9, 10),
		strconv.Itoa(officers),
		name,
	}, nil
}

// parsePerson — person record layout (0-based character positions):
//
//	[0:8]   company number
//	[8]     record type '2'
//	[9]     appointment date origin
//	[10:12] appointment type
//	[12:24] person number
//	[24]    corporate indicator
//	[25:32] filler
//	[32:40] appointment date
//	[40:48] resignation date
//	[48:56] postcode
//	[56:64] partial date of birth
//	[64:72] full date of birth
//	[72:76] variable-data length
//	[76:]   variable data: 14 fields separated by '<'
//	        Title, Forenames, Surname, Honours, Care_of, PO_box,
//	        Address line 1, Address line 2, Post_town, County, Country,
//	        Occupation, Nationality, Resident Country
func parsePerson(chars []rune) ([]string, error) {
	varLen, err := atoiField(charString(chars, 72, 76))
	if err != nil {
		return nil, fmt.Errorf("variable data length: %w", err)
	}
	variable := charString(chars, 76, 76+varLen)
	parts := strings.Split(variable, "<")

	// Pad to 14 variable fields (empty if missing).
	fields := make([]string, 14)
	for i := 0; i < 14 && i < len(parts); i++ {
		fields[i] = parts[i]
	}

	return []string{
		charString(chars, 0, 8),
		charString(chars, 9, 10),
		charString(chars, 10, 12),
		charString(chars, 12, 24),
		charString(chars, 24, 25),
		charString(chars, 32, 40),
		charString(chars, 40, 48),
		charString(chars, 48, 56),
		charString(chars, 56, 64),
		charString(chars, 64, 72),
		fields[0], fields[1], fields[2], fields[3], fields[4], fields[5],
		fields[6], fields[7], fields[8], fields[9], fields[10], fields[11],
		fields[12], fields[13],
	}, nil
}

// charString returns characters [start:end) from a rune slice, clamping to bounds.
// Empty if the range is empty or out of range — same idea as Python s[start:end].
func charString(chars []rune, start, end int) string {
	if start < 0 {
		start = 0
	}
	if end > len(chars) {
		end = len(chars)
	}
	if start >= end {
		return ""
	}
	return string(chars[start:end])
}

func atoiField(s string) (int, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0, nil
	}
	return strconv.Atoi(s)
}
