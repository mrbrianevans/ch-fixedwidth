**DISQUALIFIED PERSONS VIA FTP**  
**SPECIFICATION**  
**BULK-DATA PRODUCTS**  
**Product 192**  
**May 2024**

# Contents

1. FILE SPECIFICATION  
   2 RECORD TYPES  
   2.1 Header Record  
   2.2 Trailer Record  
   2.3 Disqualification Records  
   2.3.1 Record Type 1  
   2.3.2 Record Type 2  
   2.3.3 Record Type 3  
   2.3.4 Record Type 4

# FILE SPECIFICATION

1. Specification
> This specification details information which appears on the following Disqualified-Persons' Bulk-Data products.

2. Medium
> ~~The Companies-House Disqualified-Directors' Register Snapshot is supplied as a text file which is either placed on the client's site via FTP or placed on a suitable site from where the client can collect the data.~~
>
> The Companies-House Disqualified-Directors' Register Snapshot is supplied as a text file. It is available via sftp at bulk-live.companieshouse.gov.uk

3. Distribution
> The file is produced weekly and will normally be available on a Saturday morning.

4. Further Information
> Specifications for other data products provided by Companies House containing file layouts and content may be obtained from:

Customer Care  
Companies House  
Crown Way  
CARDIFF  
CF14 3UZ

(Tel: 029 20381312)

5. File Layout
> Each file contains the following records:

- 1 Header record.
- Disqualification detail records (approximately 15,000).
- 1 Trailer record.

# 2 RECORD TYPES

## 2.1 Header Record

Fixed Length: 20 bytes.

| START BYTE | FORMAT | LENGTH | FIELD NAME         | VALUE     |
|------------|--------|--------|--------------------|-----------|
| 1          | X      | 8      | Header Identifier  | "DISQUALS"|
| 9          | 9      | 4      | Run Number         |           |
| 13         | 9      | 8      | Production Date    | CCYYMMDD  |

## 2.2 Trailer Record

Fixed Length: 53 bytes.

| START BYTE | FORMAT | LENGTH | FIELD NAME                                      | VALUE     |
|------------|--------|--------|-------------------------------------------------|-----------|
| 1          | X      | 8      | Trailer Identifier                              | "DISQUALS"|
| 9          | X      | 1      |                                                 | "/"       |
| 10         | 9      | 8      | Type 1 Record Count                             |           |
| 18         | X      | 1      |                                                 | "/"       |
| 19         | 9      | 8      | Type 2 Record Count                             |           |
| 27         | X      | 1      |                                                 | "/"       |
| 28         | 9      | 8      | Type 3 Record Count                             |           |
| 36         | X      | 1      |                                                 | "/"       |
| 37         | 9      | 8      | Type 4 Record Count                             |           |
| 45         | X      | 1      |                                                 | "/"       |
| 46         | 9      | 8      | Total Record Count (excluding Header & Trailer) |           |

## 2.3 Disqualification Records

The following record types will be created from our current register of disqualified persons:

**RECORD TYPE 1 Person**
> PERSON DETAILS (Includes 12-character number).

CORPORATE-NUMBER (if corporate director)  
COUNTRY-REGISTRATION (if corporate director)

**RECORD TYPE 2 Disqualification**  
START DATE - END DATE (Format CCYYMMDD)  
SECTION OF THE ACT (section applicable to disqualification)  
DISQUALIFICATION-TYPE (order/ undertaking/ **sanction**)  
DISQUALIFICATION DATE  
CASE NUMBER  
COURT NAME  
COMPANY NAME

This record type could be repeated if a person is disqualified under different sections of the Act.

This record type could be repeated if more than one company has been nominated on the form. Note that the company names are provided by the court and do not necessarily cover all the directorships of the director involved.

**RECORD TYPE 3 Exemption to the disqualification**  
EXEMPTION START DATE (Format CCYYMMDD)  
EXEMPTION END DATE (Format CCYYMMDD)  
EXEMPTION-PURPOSE  
EXEMPTION-COMPANY NAME

This record type may not be present at all but can be repeated following a record type 2 for multiple exemptions.

**RECORD TYPE 4 Variations of the disqualification**  
PERSON NUMBER  
DISQUALIFICATION-TYPE  
DISQUAL-START-DATE (Format CCYYMMDD)  
VARIATION-COURT-ACTION-DATE  
VARIATION-CASE-NUMBER  
VARIATION-COURT-NAME

This record type may not be present at all and will only appear if a disqualification has been varied by the court. The record will follow the disqualification record it applies to or, if an exemption record is also applicable to the officer, it will follow the exemption record.

Note that if a disqualification is ceased by the court, the disqualification record will be deleted from the register; no information will appear in this product concerning the ceased disqualification.

### 2.3.1 Record Type 1 - Person

Variable length. Maximum length = 1215 Bytes.

| START BYTE | FORMAT | LENGTH                                          | FIELD NAME           | VALUE |
|------------|--------|-------------------------------------------------|----------------------|-------|
| 1          | X      | 1                                               | RECORD-TYPE          | "1"   |
| 2          | 9      | 12                                              | PERSON-NUMBER        |       |
| 14         | X      | 8                                               | PERSON-DATE-OF-BIRTH |       |
| 22         | X      | 8                                               | PERSON-POSTCODE      |       |
| 30         | 9      | 4                                               | PERSON-VARIABLE-IND  |       |
| 34         | X      | occurs 0 to 1182 depending on PERSON-VARIABLE-IND | PERSON-DETAILS     |       |

PERSON-VARIABLE-IND will contain the number of characters that are required to hold the PERSON-DETAILS.

PERSON-DETAILS are held in the following format:

> Title\<Forenames\<Surname\<Honours\<Address Line 1\<Address Line 2\<Posttown\<County\<Country\<Nationality\<Corporate-Number\<Country-Registration\<

- Forenames can be a maximum of 101 characters. This will be made up of forename-1 (up to 50 characters), one character space, forename-2 (up to 50 characters).
- Surname can be a maximum of 160 characters. This may contain the company name in the case of a corporate director.
- Address Line1 can be a maximum of 251 characters. This will be made up of house-name-number (up to 200 characters, one character space, street-name (up to 50 characters).
- For the DISQUALIFICATION-TYPE of sanction, the Posttown may be 'Not available'.
- Nationality can be a maximum of 50 characters. For the DISQUALIFICATION-TYPE of sanction, Nationality may be blank.
- Corporate-Number can be a maximum of 160 characters (only used for corporate directors).
- Country-Registration can be a maximum of 160 characters (only used for corporate directors).
- All the other elements can be a maximum of 50 characters.
- The maximum length is 1182 characters, which includes the 12 "\<".

### 2.3.2 Record Type 2 - Disqualification

Variable Length. Maximum length = 4281 bytes.

| START BYTE | FORMAT | LENGTH                                              | FIELD NAME                     | VALUE                                                                 |
|------------|--------|-----------------------------------------------------|--------------------------------|-----------------------------------------------------------------------|
| 1          | X      | 1                                                   | RECORD-TYPE                    | "2"                                                                   |
| 2          | 9      | 12                                                  | PERSON-NUMBER                  |                                                                       |
| 14         | X      | 8                                                   | DISQUAL-START-DATE             | CCYYMMDD                                                              |
| 22         | X      | 8                                                   | DISQUAL-END-DATE               | CCYYMMDD<br>Sanction will have a date of 99991231                     |
| 30         | X      | 20                                                  | SECTION-OF-THE-ACT             |                                                                       |
| 42         | X      | 30                                                  | DISQUALIFICATION-TYPE          | "ORDER" or "UNDERTAKING" or "SANCTION"                                |
| 72         | X      | 8                                                   | DISQUAL-ORDER/UNDERTAKING-DATE | CCYYMMDD or blank for older records. Null for sanction                |
| 80         | X      | 30                                                  | CASE-NUMBER                    |                                                                       |
| 110        | X      | 160                                                 | COMPANY-NAME                   |                                                                       |
| 270        | 9      | 4                                                   | COURT-NAME-VARIABLE-IND        |                                                                       |
| 274        | X      | occurs 0 to 4000 depending on COURT-NAME-VARIABLE-IND | COURT-NAME                   | Contains the court name for orders, "INSOLVENCY SERVICE" for undertakings, and null for sanction. |

### 2.3.3 Record Type 3 - Exemption

Variable Length. Maximum length = 203 bytes

| START BYTE | FORMAT | LENGTH                                                | FIELD NAME                 | VALUE                                        |
|------------|--------|-------------------------------------------------------|----------------------------|----------------------------------------------|
| 1          | X      | 1                                                     | RECORD-TYPE                | "3"                                          |
| 2          | 9      | 12                                                    | PERSON-NUMBER              |                                              |
| 14         | X      | 8                                                     | EXEMPTION-START-DATE       | CCYYMMDD                                     |
| 22         | X      | 8                                                     | EXEMPTION -END-DATE        | CCYYMMDD                                     |
| 30         | 9      | 10                                                    | EXEMPTION-PURPOSE          | "1", "2", "3", "4", "5" or Null for sanction |
| 40         | X      | 4                                                     | EXEMPTION-COMPANY-NAME-IND |                                              |
| 44         | X      | Occurs 0 to 160 depending on EXEMPTION-COMPANY-NAME-IND | EXEMPTION-COMPANY NAME   |                                              |

This record will occur for each company from which the disqualified person is exempt from disqualification. It will follow the person record to whom it relates and his/her disqualification records.

The values in EXEMPTION-PURPOSE will be one of the following:

1 representing "Promotion"  
2 representing "Formation"  
3 representing "Directorships or other participation in management of a company"  
4 representing "Designated member/member or other participation in management of an LLP"  
5 representing "Receivership in relation to a company or LLP".

Null for the DISQUALIFICATION-TYPE of sanction

### 2.3.4 Record Type 4 - Variation

Variable Length Maximum length = 4093bytes.

| START BYTE | FORMAT | LENGTH                                               | FIELD NAME                     | VALUE                              |
|------------|--------|------------------------------------------------------|--------------------------------|------------------------------------|
| 1          | X      | 1                                                    | RECORD-TYPE                    | "4"                                |
| 2          | 9      | 12                                                   | PERSON-NUMBER                  |                                    |
| 14         | X      | 30                                                   | DISQUALIFICATION-TYPE          | "ORDER", "UNDERTAKING" or "SANCTION" |
| 44         | X      | 8                                                    | DISQUAL-ORDER/UNDERTAKING-DATE | CCYYMMDD or blank for older records |
| 52         | X      | 8                                                    | VARIATION-COURT-ACTION-DATE    | CCYYMMDD                           |
| 60         | X      | 30                                                   | VARIATION-CASE-NUMBER          |                                    |
| 90         | X      | 4                                                    | VARIATION-COURT-NAME-IND       |                                    |
| 94         | X      | Occurs 0 to 4000 depending on VARIATION-COURT-NAME-IND | VARIATION-COURT-NAME         |                                    |

This record will occur when there is a variation of the disqualification dates. Note that if the disqualification is ceased, no information will appear on this record and all information on the disqualification will have been removed from the register.

The record will either follow the disqualification record it relates to or, if there is also an exemption record relating to the disqualified person, it will follow that.

For all record types, the date items will be in the format CCYYMMDD or, in the case of date of birth, it could be set to the default value of spaces if the date of birth is unknown.