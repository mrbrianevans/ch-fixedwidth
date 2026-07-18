# Companies House Product 195 & 216 - Company Appointments Snapshot

**File Type**: Snapshot (`DDDDSNAP` header)

**General**  
- Contains Header + multiple Company + Person records + Trailer  
- Records are sequential.  
- Dates: `CCYYMMDD` or spaces.  
- Delimiters: `<` (chevron).  
- Person numbers: 12-digit numeric.  
- Company numbers: 8 chars.

## 1. Header Record (Fixed, 20 bytes)
| Start | End | Length | Field | Type | Notes |
|-------|-----|--------|-------|------|-------|
| 1     | 8   | 8      | Header Identifier | String | `DDDDSNAP` |
| 9     | 12  | 4      | Run Number | Numeric | |
| 13    | 20  | 8      | Production Date | Date | `CCYYMMDD` |

## 2. Trailer Record (Fixed, 16 bytes)
| Start | End | Length | Field | Type | Notes |
|-------|-----|--------|-------|------|-------|
| 1     | 8   | 8      | Trailer Identifier | String | `99999999` |
| 9     | 16  | 8      | Record Count | Numeric | Excludes header/trailer |

## 3. Company Record
**Variable length**, max 201 bytes.

| Start | End | Length | Field | Type | Notes |
|-------|-----|--------|-------|------|-------|
| 1     | 8   | 8      | Company Number | String | |
| 9     | 9   | 1      | Record Type | Char | `1` |
| 10    | 10  | 1      | Company Status | Char | `C/D/L/R`/space |
| 11    | 32  | 22     | Filler | - | |
| 33    | 36  | 4      | Number of Officers | Numeric | |
| 37    | 40  | 4      | Company Name Length | Numeric | Includes `<` |
| 41    | ... | var    | Company Name | String | `<` delimited |

## 4. Person Record
**Variable length**, max 992 bytes.

| Start | End | Length | Field | Type | Notes |
|-------|-----|--------|-------|------|-------|
| 1     | 8   | 8      | Company Number | String | |
| 9     | 9   | 1      | Record Type | Char | `2` |
| 10    | 10  | 1      | App Date Origin | Char | 1-6 |
| 11    | 12  | 2      | Appointment Type | Numeric | 00/01/04/05/11-13/17-19 |
| 13    | 24  | 12     | Person Number | Numeric | |
| 25    | 25  | 1      | Corporate Indicator | Char | `Y`/space |
| 26    | 32  | 7      | Filler | - | |
| 33    | 40  | 8      | Appointment Date | Date | |
| 41    | 48  | 8      | Resignation Date | Date | |
| 49    | 56  | 8      | Person Postcode | String | |
| 57    | 64  | 8      | Partial DOB | String | `CCYYMM  ` |
| 65    | 72  | 8      | Full DOB | Date | |
| 73    | 76  | 4      | Variable Data Length | Numeric | |
| 77    | ... | var    | Variable Data | String | 14 `<` fields: Title/Forenames/Surname/Honours/CareOf/POBox/Addr1/Addr2/PostTown/County/Country/Occupation/Nationality/UsualResCountry |

**Parser Notes**: Use length field for variable data. Consecutive `<` = empty. Resignations usually excluded from snapshot.


## More info
Further notes on the record types are available at: https://chguide.co.uk/bulk-data/officers/recordTypes

## Sample data
First 10 lines of a file - doesn't include trailer record.
```
DDDDSNAP425720260706
029052131D                      00160024I.T.K. (SAFETY) LIMITED<                                                                                                                                         
029052132302900006800001Y       1994030719940307L2 9RP                  0116<<CORPORATE ADMINISTRATION SECRETARIES LIMITED<<<<FALCON HOUSE<24 NORTH JOHN STREET<LIVERPOOL<MERSEYSIDE<<<BRITISH<<
029052132102038532340001        1995060119990201BB3 3LD 196608          0088<DAVID ROY<EVANS<<<<86 POLE LANE<DARWEN<LANCASHIRE<<<FINANCIAL DIRECTOR<BRITISH<ENGLAND<
029052132102038532340001        1994030719950602BB3 3LD 196608          0088<DAVID ROY<EVANS<<<<86 POLE LANE<DARWEN<LANCASHIRE<<<FINANCIAL DIRECTOR<BRITISH<ENGLAND<
029052132100099231120001        20040722        GU21 4RZ196701          0079MR<JONATHAN<GALE<<<<15 ORMONDE ROAD<<WOKING<SURREY<<ACCOUNTANT<BRITISH<ENGLAND<
029052132102103424200001        2002060120030331HP10 0PN197110          0102<SHIRLEY JOANNE<HAWKINS<FCCA<<<4 PROSPECT COTTAGES<<WOOBURN TOWN<BUCKINGHAMSHIRE<<ACCOUNTANT<BRITISH<<
029052132102063066030001        1999020120020601GU15 4JS196105          0069<NEIL JOSEPH<MATHEWS<<<<40 COLLEGE RIDE<<CAMBERLEY<SURREY<<<BRITISH<<
029052132102113323290001        2003080120040722GU6 8HF 196409          0083<JULIAN GALSWORTHY<PALMER<<<<CARTERS CROFT<GUILDFORD ROAD<ALFOLD<SURREY<<<BRITISH<<
029052132103043088880001        1995060120030731ST11 9JG194901          0104<NORMAN STUART<BEARDMORE<<<<78 UTTOXETER ROAD<BLYTHE BRIDGE<STOKE ON TRENT<<<MANAGING DIRECTOR<BRITISH<<
```