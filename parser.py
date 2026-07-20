# courtesy of https://github.com/Global-Witness/uk-companies-house-parsers-public/blob/master/process_company_appointments_data.py
# Maximum single-core optimized version. <30 seconds to process a 1.3GB file.

import csv
import os
import sys

COMPANIES_OUTPUT_FILENAME_TEMPLATE = "companies_data_%s.csv"
PERSONS_OUTPUT_FILENAME_TEMPLATE = "persons_data_%s.csv"
SNAPSHOT_HEADER_IDENTIFIER = "DDDDSNAP"
TRAILER_RECORD_IDENTIFIER = "99999999"

# Pre-compile constants
COMPANY_RECORD_TYPE = '1'
PERSON_RECORD_TYPE = '2'
BATCH_SIZE = 30000

# Pre-define headers as tuples (faster than lists for constants)
COMPANIES_HEADER = ("Company Number", "Company Status", "Number of Officers", "Company Name")
PERSONS_HEADER = (
    "Company Number", "App Date Origin", "Appointment Type", "Person number", "Corporate indicator", 
    "Appointment Date", "Resignation Date", "Person Postcode", "Partial Date of Birth", "Full Date of Birth", 
    "Title", "Forenames", "Surname", "Honours", "Care_of", "PO_box", "Address line 1", "Address line 2", 
    "Post_town", "County", "Country", "Occupation", "Nationality", "Resident Country"
)

def process_header_row(row):
    if row[:8] != SNAPSHOT_HEADER_IDENTIFIER:
        print(f"Unsupported file type from header: '{row[:8]}'. Expecting: '{SNAPSHOT_HEADER_IDENTIFIER}'")
        sys.exit(1)
    print(f"Processing snapshot file with run number {row[8:12]} from date {row[12:20]}")

def process_company_row_ultra_fast(row):
    # Ultra minimal - only operations that are absolutely necessary
    name_length = int(row[36:40])
    company_name = row[40:40 + name_length - 1]
    
    return (
        row[:8],           # company_number - no strip, fixed width
        row[9],            # company_status - single char
        int(row[32:36]),   # number_of_officers
        company_name.rstrip() if company_name.endswith(' ') else company_name
    )

def process_person_row_ultra_fast(row):
    # Pre-calculate once
    variable_data_length = int(row[72:76])
    variable_data = row[76:76 + variable_data_length]
    
    # Single split operation
    parts = variable_data.split('<')
    parts_count = len(parts)
    
    # Direct indexing with fallback - fastest approach
    return (
        row[:8],           # company_number
        row[9],            # app_date_origin
        row[10:12],        # appointment_type
        row[12:24],        # person_number
        row[24],           # corporate_indicator
        row[32:40],        # appointment_date
        row[40:48],        # resignation_date
        row[48:56],        # postcode
        row[56:64],        # partial_date_of_birth
        row[64:72],        # full_date_of_birth
        parts[0] if parts_count > 0 else '',   # title
        parts[1] if parts_count > 1 else '',   # forenames
        parts[2] if parts_count > 2 else '',   # surname
        parts[3] if parts_count > 3 else '',   # honours
        parts[4] if parts_count > 4 else '',   # care_of
        parts[5] if parts_count > 5 else '',   # po_box
        parts[6] if parts_count > 6 else '',   # address_line_1
        parts[7] if parts_count > 7 else '',   # address_line_2
        parts[8] if parts_count > 8 else '',   # post_town
        parts[9] if parts_count > 9 else '',   # county
        parts[10] if parts_count > 10 else '', # country
        parts[11] if parts_count > 11 else '', # occupation
        parts[12] if parts_count > 12 else '', # nationality
        parts[13] if parts_count > 13 else ''  # res_country
    )

def process_company_appointments_data(input_file, output_folder, base_input_name):
    companies_processed = 0
    persons_processed = 0
    
    # Setup output files
    os.makedirs(output_folder, exist_ok=True)
    companies_filename = os.path.join(output_folder, COMPANIES_OUTPUT_FILENAME_TEMPLATE % base_input_name)
    persons_filename = os.path.join(output_folder, PERSONS_OUTPUT_FILENAME_TEMPLATE % base_input_name)
    
    print(f"Saving companies data to {companies_filename}")
    print(f"Saving persons data to {persons_filename}")
    
    # Open files with maximum buffer sizes
    companies_file = open(companies_filename, 'w', encoding='utf-8', newline='', buffering=4*1024*1024)
    persons_file = open(persons_filename, 'w', encoding='utf-8', newline='', buffering=4*1024*1024)
    
    # Create writers
    companies_writer = csv.writer(companies_file, delimiter=",")
    persons_writer = csv.writer(persons_file, delimiter=",")
    
    # Write headers immediately
    companies_writer.writerow(COMPANIES_HEADER)
    persons_writer.writerow(PERSONS_HEADER)
    
    # Pre-allocate lists with expected size to avoid reallocation
    companies_batch = []
    persons_batch = []
    
    try:
        # Use enumerate for faster iteration
        for row_num, row in enumerate(input_file):
            if row_num == 0:
                process_header_row(row)
                continue
                
            # Fast trailer check - compare first 8 chars directly
            if row.startswith(TRAILER_RECORD_IDENTIFIER):
                # Flush remaining batches
                if companies_batch:
                    companies_writer.writerows(companies_batch)
                if persons_batch:
                    persons_writer.writerows(persons_batch)
                
                # Verify record count
                record_count = int(row[8:16])
                total_processed = companies_processed + persons_processed
                
                if record_count == total_processed:
                    print(f"Processed {total_processed} records: {companies_processed} companies, {persons_processed} persons.")
                    return 0
                else:
                    print(f"ERROR: Processed {total_processed} records out of {record_count}")
                    return 1
            
            # Single character lookup - fastest record type check
            record_type = row[8]
            if record_type == COMPANY_RECORD_TYPE:
                companies_batch.append(process_company_row_ultra_fast(row))
                companies_processed += 1
                
                # Batch write when full
                if len(companies_batch) >= BATCH_SIZE:
                    companies_writer.writerows(companies_batch)
                    companies_batch = []  # Reset list
                    
            elif record_type == PERSON_RECORD_TYPE:
                persons_batch.append(process_person_row_ultra_fast(row))
                persons_processed += 1
                
                # Batch write when full
                if len(persons_batch) >= BATCH_SIZE:
                    persons_writer.writerows(persons_batch)
                    persons_batch = []  # Reset list
    
    finally:
        companies_file.close()
        persons_file.close()
    
    print("ERROR: File ended abruptly. Did not find a TRAILER_RECORD_IDENTIFIER.")
    return 1

if __name__ == '__main__':
    if len(sys.argv) < 3:
        print(
            'Usage: python process_company_appointments_data.py input_file output_folder\n'
            'E.g. python process_company_appointments_data.py Prod195_1111_ni_sample.dat ./output/'
        )
        sys.exit(1)
    
    input_filename = sys.argv[1]
    output_folder = sys.argv[2]
    
    # Maximum input buffer size
    with open(input_filename, 'r', encoding='utf-8', buffering=8*1024*1024) as input_file:
        base_input_name = os.path.splitext(os.path.basename(input_filename))[0]
        exit_code = process_company_appointments_data(input_file, output_folder, base_input_name)
        sys.exit(exit_code)