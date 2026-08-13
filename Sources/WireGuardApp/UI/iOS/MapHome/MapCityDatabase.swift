// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Ryan Tenney.
//
// GENERATED FILE - DO NOT EDIT BY HAND.
// Regenerate with: python3 scripts/generate-map-data.py
//
// City database for the endpoint location picker, from Natural Earth 1:50m
// populated places (public domain): capitals, cities over 1M population,
// and common VPN hub cities. 528 entries.

import Foundation

enum MapCityDatabase {

    /// All known cities, sorted by name.
    static let cities: [MapCity] = records.split(separator: "\n").compactMap { line in
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 5,
              let latitude = Double(fields[3]),
              let longitude = Double(fields[4]) else { return nil }
        return MapCity(name: String(fields[0]),
                       country: String(fields[1]),
                       countryCode: String(fields[2]),
                       latitude: latitude,
                       longitude: longitude)
    }

    private static let records = """
Abidjan|Ivory Coast|CI|5.32|-4.02
Abu Dhabi|United Arab Emirates|AE|24.47|54.37
Abuja|Nigeria|NG|9.05|7.49
Accra|Ghana|GH|5.55|-0.22
Adana|Turkey|TR|37.00|35.32
Addis Ababa|Ethiopia|ET|9.04|38.70
Adelaide|Australia|AU|-34.93|138.60
Aden|Yemen|YE|12.78|45.01
Agra|India|IN|27.17|78.01
Ahmedabad|India|IN|23.03|72.58
Aleppo|Syria|SY|36.23|37.17
Alexandria|Egypt|EG|31.20|29.95
Algiers|Algeria|DZ|36.77|3.05
Allahabad|India|IN|25.46|81.84
Almaty|Kazakhstan|KZ|43.33|76.91
Amaravati|India|IN|16.53|80.52
Amman|Jordan|JO|31.95|35.93
Amritsar|India|IN|31.64|74.87
Amsterdam|Netherlands|NL|52.35|4.91
Andorra|Andorra|AD|42.51|1.53
Ankang|China|CN|32.68|109.02
Ankara|Turkey|TR|39.93|32.86
Anshan|China|CN|41.12|122.94
Antananarivo|Madagascar|MG|-18.91|47.51
Apia|Samoa|WS|-13.84|-171.77
Arequipa|Peru|PE|-16.42|-71.53
Asansol|India|IN|23.69|86.98
Ashgabat|Turkmenistan|TM|37.95|58.38
Asmara|Eritrea|ER|15.33|38.93
Asunción|Paraguay|PY|-25.29|-57.63
Athens|Greece|GR|37.99|23.73
Atlanta|United States|US|33.74|-84.37
Auckland|New Zealand|NZ|-36.85|174.76
Aurangabad|India|IN|19.86|75.33
Austin|United States|US|30.27|-97.74
Baghdad|Iraq|IQ|33.34|44.39
Baguio|Philippines|PH|16.43|120.57
Baku|Azerbaijan|AZ|40.40|49.86
Baltimore|United States|US|39.28|-76.61
Bamako|Mali|ML|12.65|-8.00
Bandar Seri Begawan|Brunei|BN|4.88|114.93
Bandung|Indonesia|ID|-6.95|107.57
Banghazi|Libya|LY|32.12|20.06
Bangkok|Thailand|TH|13.75|100.51
Bangui|Central African Republic|CF|4.37|18.56
Banjul|The Gambia|GM|13.45|-16.59
Baoshan|China|CN|25.12|99.15
Baotou|China|CN|40.65|109.82
Barcelona|Spain|ES|41.39|2.18
Barranquilla|Colombia|CO|10.96|-74.80
Basseterre|Saint Kitts and Nevis|KN|17.30|-62.72
Beijing|China|CN|39.90|116.39
Beirut|Lebanon|LB|33.87|35.51
Belfast|United Kingdom|GB|54.59|-5.93
Belgrade|Serbia|RS|44.82|20.47
Belmopan|Belize|BZ|17.25|-88.77
Belo Horizonte|Brazil|BR|-19.91|-43.92
Belém|Brazil|BR|-1.45|-48.48
Bengaluru|India|IN|12.97|77.56
Benin City|Nigeria|NG|6.34|5.62
Bergen|Norway|NO|60.39|5.32
Berlin|Germany|DE|52.52|13.40
Bern|Switzerland|CH|46.92|7.47
Bhilai|India|IN|21.21|81.37
Bhopal|India|IN|23.25|77.41
Bilbao|Spain|ES|43.25|-2.93
Bir Lehlou|Western Sahara|EH|26.12|-9.65
Birmingham|United Kingdom|GB|52.48|-1.92
Bishkek|Kyrgyzstan|KG|42.88|74.58
Bissau|Guinea Bissau|GW|11.87|-15.60
Bloemfontein|South Africa|ZA|-29.12|26.23
Bogota|Colombia|CO|4.60|-74.09
Bologna|Italy|IT|44.50|11.34
Bordeaux|France|FR|44.85|-0.60
Boston|United States|US|42.33|-71.07
Brasília|Brazil|BR|-15.78|-47.92
Bratislava|Slovakia|SK|48.15|17.12
Brazzaville|Congo (Brazzaville)|CG|-4.26|15.28
Bridgeport|United States|US|41.18|-73.20
Bridgetown|Barbados|BB|13.10|-59.62
Brisbane|Australia|AU|-27.45|153.03
Brussels|Belgium|BE|50.84|4.33
Bucharest|Romania|RO|44.44|26.10
Budapest|Hungary|HU|47.50|19.08
Buenos Aires|Argentina|AR|-34.61|-58.43
Buffalo|United States|US|42.88|-78.88
Bujumbura|Burundi|BI|-3.38|29.36
Bursa|Turkey|TR|40.20|29.07
Busan|South Korea|KR|35.10|129.01
Cairo|Egypt|EG|30.05|31.25
Calgary|Canada|CA|51.08|-114.08
Cali|Colombia|CO|3.40|-76.50
Campinas|Brazil|BR|-22.91|-47.06
Canberra|Australia|AU|-35.28|149.13
Cape Town|South Africa|ZA|-33.92|18.43
Caracas|Venezuela|VE|10.50|-66.92
Cardiff|United Kingdom|GB|51.48|-3.17
Casablanca|Morocco|MA|33.60|-7.62
Castries|Saint Lucia|LC|14.01|-60.99
Cebu|Philippines|PH|10.32|123.90
Changchun|China|CN|43.87|125.34
Changsha|China|CN|28.20|112.97
Chattogram|Bangladesh|BD|22.33|91.80
Chelyabinsk|Russia|RU|55.16|61.44
Chengdu|China|CN|30.67|104.07
Chennai|India|IN|13.09|80.28
Chiang Mai|Thailand|TH|18.80|98.98
Chicago|United States|US|41.85|-87.64
Chifeng|China|CN|42.27|118.95
Chișinău|Moldova|MD|47.01|28.86
Chongqing|China|CN|29.57|106.59
Christchurch|New Zealand|NZ|-43.54|172.63
Cincinnati|United States|US|39.16|-84.46
Cleveland|United States|US|41.47|-81.70
Coimbatore|India|IN|11.00|76.95
Colombo|Sri Lanka|LK|6.93|79.86
Conakry|Guinea|GN|9.53|-13.68
Cotonou|Benin|BJ|6.36|2.40
Curitiba|Brazil|BR|-25.42|-49.32
Córdoba|Argentina|AR|-31.40|-64.18
Da Nang|Vietnam|VN|16.06|108.25
Daejeon|South Korea|KR|36.34|127.42
Dakar|Senegal|SN|14.72|-17.48
Dalian|China|CN|38.92|121.63
Dallas|United States|US|32.77|-96.79
Damascus|Syria|SY|33.50|36.30
Daqing|China|CN|46.58|125.00
Dar es Salaam|Tanzania|TZ|-6.80|39.27
Davao|Philippines|PH|7.11|125.63
Delhi|India|IN|28.67|77.23
Denver|United States|US|39.74|-104.99
Detroit|United States|US|42.33|-83.05
Dhaka|Bangladesh|BD|23.73|90.41
Dhanbad|India|IN|23.80|86.42
Dili|East Timor|TL|-8.56|125.58
Djibouti|Djibouti|DJ|11.60|43.15
Dnipro|Ukraine|UA|48.48|35.00
Dodoma|Tanzania|TZ|-6.18|35.75
Doha|Qatar|QA|25.29|51.53
Dongguan|China|CN|23.02|113.75
Douala|Cameroon|CM|4.06|9.71
Dubai|United Arab Emirates|AE|25.21|55.29
Dublin|Ireland|IE|53.35|-6.26
Durban|South Africa|ZA|-29.86|31.01
Dushanbe|Tajikistan|TJ|38.56|68.77
Edinburgh|United Kingdom|GB|55.95|-3.22
Edmonton|Canada|CA|53.55|-113.50
Faridabad|India|IN|28.44|77.31
Fez|Morocco|MA|34.06|-5.00
Florence|Italy|IT|43.78|11.25
Florianópolis|Brazil|BR|-27.58|-48.52
Fortaleza|Brazil|BR|-3.75|-38.58
Frankfurt|Germany|DE|50.10|8.68
Freetown|Sierra Leone|SL|8.47|-13.24
Ft.  Worth|United States|US|32.74|-97.34
Fukuoka|Japan|JP|33.60|130.41
Funafuti|Tuvalu|TV|-8.52|179.22
Fuzhou|China|CN|26.08|119.30
Gaborone|Botswana|BW|-24.65|25.91
Geneva|Switzerland|CH|46.21|6.14
Genoa|Italy|IT|44.41|8.93
George Town|Malaysia|MY|5.41|100.33
Georgetown|Guyana|GY|6.80|-58.17
Ghaziabad|India|IN|28.66|77.41
Glasgow|United Kingdom|GB|55.86|-4.24
Goiânia|Brazil|BR|-16.72|-49.30
Guadalajara|Mexico|MX|20.67|-103.33
Guangzhou|China|CN|23.12|113.26
Guatemala City|Guatemala|GT|14.62|-90.53
Guayaquil|Ecuador|EC|-2.22|-79.92
Guiyang|China|CN|26.58|106.72
Gujranwala|Pakistan|PK|32.16|74.18
Gwangju|South Korea|KR|35.17|126.91
Haiphong|Vietnam|VN|20.83|106.68
Halifax|Canada|CA|44.65|-63.60
Hamburg|Germany|DE|53.55|10.00
Handan|China|CN|36.58|114.48
Hangzhou|China|CN|30.25|120.17
Hanoi|Vietnam|VN|21.04|105.85
Harare|Zimbabwe|ZW|-17.82|31.04
Harbin|China|CN|45.75|126.65
Hargeisa|Somaliland|SO|9.56|44.07
Havana|Cuba|CU|23.13|-82.37
Hefei|China|CN|31.85|117.28
Helsinki|Finland|FI|60.16|24.93
Hengyang|China|CN|26.88|112.59
Hiroshima|Japan|JP|34.39|132.44
Ho Chi Minh City|Vietnam|VN|10.76|106.70
Hohhot|China|CN|40.82|111.66
Hong Kong|Hong Kong S.A.R.|HK|22.31|114.18
Honiara|Solomon Islands|SB|-9.44|159.95
Houston|United States|US|29.74|-95.35
Huainan|China|CN|32.63|116.98
Huaiyin|China|CN|33.59|119.07
Huambo|Angola|AO|-12.75|15.76
Hyderabad|India|IN|17.40|78.48
Hyderabad|Pakistan|PK|25.38|68.37
Ibadan|Nigeria|NG|7.38|3.93
Incheon|South Korea|KR|37.48|126.64
Indianapolis|United States|US|39.75|-86.17
Indore|India|IN|22.72|75.86
Isfahan|Iran|IR|32.70|51.70
Islamabad|Pakistan|PK|33.69|73.08
Istanbul|Turkey|TR|41.02|28.97
Jabalpur|India|IN|23.18|79.95
Jacksonville|United States|US|30.33|-81.67
Jaipur|India|IN|26.92|75.81
Jakarta|Indonesia|ID|-6.17|106.83
Jamshedpur|India|IN|22.79|86.20
Jeddah|Saudi Arabia|SA|21.52|39.22
Jerusalem|Israel|IL|31.78|35.21
Jiamusi|China|CN|46.83|130.35
Jilin|China|CN|43.85|126.55
Jinan|China|CN|36.68|116.99
Jinxi|China|CN|40.75|120.83
Johannesburg|South Africa|ZA|-26.17|28.03
Juba|South Sudan|SS|4.83|31.58
Kabul|Afghanistan|AF|34.52|69.18
Kaduna|Nigeria|NG|10.52|7.44
Kampala|Uganda|UG|0.32|32.58
Kano|Nigeria|NG|12.00|8.52
Kanpur|India|IN|26.46|80.32
Kansas City|United States|US|39.11|-94.61
Kaohsiung|Taiwan|CN-TW|22.63|120.27
Karachi|Pakistan|PK|24.87|66.99
Kathmandu|Nepal|NP|27.72|85.31
Kazan|Russia|RU|55.75|49.12
Kharkiv|Ukraine|UA|50.00|36.25
Khartoum|Sudan|SD|15.59|32.53
Khulna|Bangladesh|BD|22.84|89.56
Kigali|Rwanda|RW|-1.95|30.06
Kingston|Jamaica|JM|17.98|-76.77
Kingstown|Saint Vincent and the Grenadines|VC|13.16|-61.22
Kinshasa|Congo (Kinshasa)|CD|-4.33|15.31
Kochi|India|IN|10.02|76.22
Kolkata|India|IN|22.57|88.37
Kuala Lumpur|Malaysia|MY|3.14|101.69
Kunming|China|CN|25.04|102.70
Kuwait City|Kuwait|KW|29.37|47.98
Kyiv|Ukraine|UA|50.44|30.51
Kyoto|Japan|JP|35.03|135.75
København|Denmark|DK|55.68|12.56
La Paz|Bolivia|BO|-16.50|-68.15
Laayoune|Morocco|MA|27.15|-13.20
Lagos|Nigeria|NG|6.45|3.39
Lahore|Pakistan|PK|31.56|74.35
Lanzhou|China|CN|36.06|103.79
Las Vegas|United States|US|36.16|-115.15
León|Mexico|MX|21.15|-101.70
Libreville|Gabon|GA|0.39|9.46
Lille|France|FR|50.65|3.08
Lilongwe|Malawi|MW|-13.98|33.78
Lima|Peru|PE|-12.05|-77.05
Linyi|China|CN|35.08|118.33
Lisbon|Portugal|PT|38.72|-9.15
Liupanshui|China|CN|26.60|104.83
Ljubljana|Slovenia|SI|46.06|14.51
Lobamba|eSwatini|SZ|-26.47|31.20
Lomé|Togo|TG|6.13|1.22
London|United Kingdom|GB|51.50|-0.12
Los Angeles|United States|US|34.05|-118.23
Luanda|Angola|AO|-8.84|13.23
Lubumbashi|Congo (Kinshasa)|CD|-11.68|27.48
Lucknow|India|IN|26.86|80.91
Ludhiana|India|IN|30.93|75.87
Lusaka|Zambia|ZM|-15.41|28.28
Luxembourg|Luxembourg|LU|49.61|6.13
Lviv|Ukraine|UA|49.83|24.03
Lyon|France|FR|45.77|4.83
Maceió|Brazil|BR|-9.62|-35.73
Madrid|Spain|ES|40.40|-3.69
Madurai|India|IN|9.92|78.12
Majuro|Marshall Islands|MH|7.10|171.38
Makassar|Indonesia|ID|-5.14|119.43
Makkah|Saudi Arabia|SA|21.43|39.82
Malabo|Equatorial Guinea|GQ|3.75|8.78
Malé|Maldives|MV|4.17|73.51
Managua|Nicaragua|NI|12.15|-86.27
Manama|Bahrain|BH|26.24|50.58
Manaus|Brazil|BR|-3.10|-60.00
Manchester|United Kingdom|GB|53.48|-2.25
Mandalay|Myanmar|MM|21.97|96.08
Manila|Philippines|PH|14.61|120.98
Maputo|Mozambique|MZ|-25.95|32.59
Maracaibo|Venezuela|VE|10.73|-71.66
Marrakesh|Morocco|MA|31.63|-8.00
Marseille|France|FR|43.29|5.37
Maseru|Lesotho|LS|-29.32|27.48
Mashhad|Iran|IR|36.27|59.57
Mbabane|eSwatini|SZ|-26.32|31.13
Mbuji-Mayi|Congo (Kinshasa)|CD|-6.15|23.60
Medan|Indonesia|ID|3.58|98.65
Medellín|Colombia|CO|6.28|-75.58
Medina|Saudi Arabia|SA|24.50|39.58
Meerut|India|IN|29.00|77.70
Melbourne|Australia|AU|-37.82|144.97
Melekeok|Palau|PW|7.49|134.63
Memphis|United States|US|35.14|-90.03
Mexico City|Mexico|MX|19.44|-99.13
Miami|United States|US|25.79|-80.23
Mianyang|China|CN|31.46|104.69
Milan|Italy|IT|45.47|9.20
Milwaukee|United States|US|43.03|-87.92
Minneapolis|United States|US|44.98|-93.25
Minsk|Belarus|BY|53.90|27.56
Mogadishu|Somalia|SO|2.07|45.36
Mombasa|Kenya|KE|-4.04|39.69
Monaco|Monaco|MC|43.74|7.41
Monrovia|Liberia|LR|6.31|-10.80
Monterrey|Mexico|MX|25.67|-100.33
Montevideo|Uruguay|UY|-34.91|-56.19
Montréal|Canada|CA|45.50|-73.59
Moroni|Comoros|KM|-11.70|43.24
Moscow|Russia|RU|55.75|37.61
Mosul|Iraq|IQ|36.35|43.14
Multan|Pakistan|PK|30.20|71.45
Mumbai|India|IN|19.07|72.88
Munich|Germany|DE|48.13|11.57
Muscat|Oman|OM|23.59|58.38
N'Djamena|Chad|TD|12.12|15.05
Nagoya|Japan|JP|35.16|136.91
Nagpur|India|IN|21.17|79.09
Nairobi|Kenya|KE|-1.28|36.81
Nanchang|China|CN|28.68|115.88
Nanchong|China|CN|30.78|106.13
Nanjing|China|CN|32.05|118.78
Nanning|China|CN|22.82|108.32
Nanyang|China|CN|33.00|112.53
Naples|Italy|IT|40.84|14.24
Nashville|United States|US|36.17|-86.78
Nasik|India|IN|20.00|73.78
Nassau|The Bahamas|BS|25.08|-77.35
Natal|Brazil|BR|-5.78|-35.24
Naypyidaw|Myanmar|MM|19.77|96.12
Neijiang|China|CN|29.58|105.05
New Delhi|India|IN|28.60|77.20
New York|United States|US|40.72|-74.00
Niamey|Niger|NE|13.52|2.11
Nicosia|Cyprus|CY|35.17|33.37
Ningbo|China|CN|29.88|121.55
Nizhny Novgorod|Russia|RU|56.33|44.00
Norfolk|United States|US|36.85|-76.28
Nouakchott|Mauritania|MR|18.09|-15.98
Novosibirsk|Russia|RU|55.03|82.96
Nuku'alofa|Tonga|TO|-21.14|-175.22
Nur-Sultan|Kazakhstan|KZ|51.18|71.43
Odessa|Ukraine|UA|46.49|30.71
Omdurman|Sudan|SD|15.62|32.48
Omsk|Russia|RU|54.99|73.40
Orlando|United States|US|28.51|-81.38
Oslo|Norway|NO|59.92|10.75
Ottawa|Canada|CA|45.42|-75.70
Ouagadougou|Burkina Faso|BF|12.37|-1.53
Palembang|Indonesia|ID|-2.98|104.75
Palermo|Italy|IT|38.13|13.35
Palikir|Federated States of Micronesia|FM|6.92|158.15
Panama City|Panama|PA|8.97|-79.53
Paramaribo|Suriname|SR|5.84|-55.17
Paris|France|FR|48.86|2.35
Patna|India|IN|25.63|85.13
Perth|Australia|AU|-31.95|115.84
Peshawar|Pakistan|PK|34.01|71.53
Philadelphia|United States|US|39.95|-75.18
Phnom Penh|Cambodia|KH|11.55|104.91
Phoenix|United States|US|33.45|-112.07
Pittsburgh|United States|US|40.43|-80.00
Podgorica|Montenegro|ME|42.47|19.27
Port Elizabeth|South Africa|ZA|-33.97|25.60
Port Harcourt|Nigeria|NG|4.81|7.01
Port Louis|Mauritius|MU|-20.17|57.50
Port Moresby|Papua New Guinea|PG|-9.46|147.19
Port Vila|Vanuatu|VU|-17.73|168.32
Port-au-Prince|Haiti|HT|18.54|-72.34
Port-of-Spain|Trinidad and Tobago|TT|10.65|-61.52
Portland|Australia|AU|-38.34|141.59
Portland|United States|US|45.52|-122.68
Porto Alegre|Brazil|BR|-30.05|-51.20
Porto-Novo|Benin|BJ|6.48|2.62
Prague|Czechia|CZ|50.09|14.42
Praia|Cape Verde|CV|14.92|-23.52
Pretoria|South Africa|ZA|-25.70|28.23
Pristina|Kosovo|XK|42.67|21.17
Puebla|Mexico|MX|19.03|-98.20
Pune|India|IN|18.52|73.85
Putrajaya|Malaysia|MY|2.93|101.70
Pyongyang|North Korea|KP|39.02|125.75
Qingdao|China|CN|36.09|120.33
Qiqihar|China|CN|47.35|123.99
Quanzhou|China|CN|24.90|118.58
Quito|Ecuador|EC|-0.21|-78.50
Rabat|Morocco|MA|34.03|-6.84
Rajkot|India|IN|22.31|70.80
Raleigh|United States|US|35.77|-78.65
Ranchi|India|IN|23.37|85.33
Recife|Brazil|BR|-8.06|-34.91
Reykjavík|Iceland|IS|64.14|-21.94
Riga|Latvia|LV|56.95|24.10
Rio de Janeiro|Brazil|BR|-22.91|-43.21
Riyadh|Saudi Arabia|SA|24.63|46.72
Rome|Italy|IT|41.90|12.48
Rosario|Argentina|AR|-32.95|-60.67
Roseau|Dominica|DM|15.30|-61.39
Rostov|Russia|RU|47.24|39.71
Sacramento|United States|US|38.58|-121.47
Saint George's|Grenada|GD|12.05|-61.74
Saint John's|Antigua and Barbuda|AG|17.12|-61.85
Salt Lake City|United States|US|40.78|-111.93
Salvador|Brazil|BR|-12.97|-38.48
Samara|Russia|RU|53.20|50.15
San Antonio|United States|US|29.42|-98.49
San Bernardino|United States|US|34.12|-117.30
San Diego|United States|US|32.72|-117.15
San Francisco|United States|US|37.78|-122.40
San Jose|United States|US|37.33|-121.89
San José|Costa Rica|CR|9.93|-84.08
San Juan|Argentina|AR|-31.55|-68.52
San Juan|Puerto Rico|PR|18.44|-66.13
San Marino|San Marino|SM|43.94|12.44
San Salvador|El Salvador|SV|13.70|-89.22
Sanaa|Yemen|YE|15.36|44.20
Santa Cruz|Bolivia|BO|-17.75|-63.23
Santiago|Chile|CL|-33.44|-70.65
Santiago|Dominican Republic|DO|19.50|-70.67
Santo Domingo|Dominican Republic|DO|18.47|-69.93
Sapporo|Japan|JP|43.08|141.34
Sarajevo|Bosnia and Herzegovina|BA|43.85|18.38
Seattle|United States|US|47.60|-122.32
Semarang|Indonesia|ID|-6.96|110.42
Sendai|Japan|JP|38.27|140.87
Seoul|South Korea|KR|37.57|127.00
Seville|Spain|ES|37.41|-5.98
Shanghai|China|CN|31.22|121.43
Shantou|China|CN|23.37|116.67
Shenyeng|China|CN|41.81|123.45
Shenzhen|China|CN|22.55|114.06
Shijiazhuang|China|CN|38.05|114.48
Shiraz|Iran|IR|29.63|52.57
Sholapur|India|IN|17.67|75.90
Singapore|Singapore|SG|1.29|103.85
Skopje|North Macedonia|MK|42.00|21.43
Sofia|Bulgaria|BG|42.69|23.31
Sri Jayawardenepura Kotte|Sri Lanka|LK|6.90|79.95
Srinagar|India|IN|34.07|74.83
St.  Petersburg|Russia|RU|59.94|30.31
St. Louis|United States|US|38.64|-90.24
Stockholm|Sweden|SE|59.32|18.07
Sucre|Bolivia|BO|-19.04|-65.26
Surabaya|Indonesia|ID|-7.25|112.75
Surat|India|IN|21.20|72.84
Suva|Fiji|FJ|-18.13|178.44
Suzhou|China|CN|31.30|120.62
Sydney|Australia|AU|-33.87|151.21
São Luís|Brazil|BR|-2.51|-44.27
São Paulo|Brazil|BR|-23.56|-46.63
São Tomé|Sao Tome and Principe|ST|0.34|6.73
Tabriz|Iran|IR|38.09|46.30
Taichung|Taiwan|CN-TW|24.15|120.68
Taipei|Taiwan|CN-TW|25.04|121.57
Taiyuan|China|CN|37.88|112.54
Tallinn|Estonia|EE|59.43|24.73
Tampa|United States|US|27.95|-82.46
Tarawa|Kiribati|KI|1.34|173.02
Tashkent|Uzbekistan|UZ|41.30|69.27
Tbilisi|Georgia|GE|41.73|44.79
Tegucigalpa|Honduras|HN|14.10|-87.22
Tehran|Iran|IR|35.67|51.42
Tel Aviv|Israel|IL|32.08|34.77
The Hague|Netherlands|NL|52.08|4.27
Thessaloniki|Greece|GR|40.70|22.88
Thimphu|Bhutan|BT|27.47|89.64
Tianjin|China|CN|39.08|117.20
Tianshui|China|CN|34.60|105.92
Tijuana|Mexico|MX|32.50|-117.08
Tirana|Albania|AL|41.33|19.82
Tokyo|Japan|JP|35.69|139.75
Toronto|Canada|CA|43.66|-79.39
Torreón|Mexico|MX|25.57|-103.42
Toulouse|France|FR|43.62|1.45
Tripoli|Libya|LY|32.89|13.18
Tunis|Tunisia|TN|36.80|10.18
Turin|Italy|IT|45.07|7.67
Ufa|Russia|RU|54.79|56.04
Ulaanbaatar|Mongolia|MN|47.92|106.91
Vadodara|India|IN|22.31|73.18
Vaduz|Liechtenstein|LI|47.13|9.52
Valencia|Spain|ES|39.49|-0.40
Valencia|Venezuela|VE|10.23|-67.98
Valletta|Malta|MT|35.90|14.51
Valparaíso|Chile|CL|-33.05|-71.62
Vancouver|Canada|CA|49.28|-123.12
Varanasi|India|IN|25.33|83.00
Vatican City|Vatican|VA|41.90|12.45
Venice|Italy|IT|45.44|12.33
Victoria|Seychelles|SC|-4.62|55.45
Vienna|Austria|AT|48.20|16.36
Vientiane|Laos|LA|17.97|102.60
Vijayawada|India|IN|16.52|80.63
Vila Velha|Brazil|BR|-20.34|-40.29
Vilnius|Lithuania|LT|54.68|25.32
Vishakhapatnam|India|IN|17.68|83.22
Warsaw|Poland|PL|52.23|21.01
Washington,  D.C.|United States|US|38.90|-77.01
Wellington|New Zealand|NZ|-41.29|174.78
Wenzhou|China|CN|28.02|120.65
Windhoek|Namibia|NA|-22.57|17.08
Winnipeg|Canada|CA|49.88|-97.17
Wuhan|China|CN|30.58|114.27
Wuxi|China|CN|31.58|120.30
Xiamen|China|CN|24.45|118.08
Xian|China|CN|34.28|108.89
Xining|China|CN|36.62|101.77
Xuzhou|China|CN|34.28|117.18
Yamoussoukro|Ivory Coast|CI|6.82|-5.28
Yangon|Myanmar|MM|16.79|96.16
Yantai|China|CN|37.53|121.40
Yaoundé|Cameroon|CM|3.87|11.51
Yekaterinburg|Russia|RU|56.85|60.60
Yerevan|Armenia|AM|40.18|44.51
Yulin|China|CN|22.63|110.15
Zagreb|Croatia|HR|45.80|16.00
Zaozhuang|China|CN|34.88|117.57
Zhanjiang|China|CN|21.20|110.38
Zhengzhou|China|CN|34.76|113.66
Zibo|China|CN|36.82|118.00
Zürich|Switzerland|CH|47.38|8.55
Ürümqi|China|CN|43.81|87.57
İzmir|Turkey|TR|38.44|27.15
Ōsaka|Japan|JP|34.69|135.50
"""
}

struct MapCity {
    let name: String
    let country: String
    let countryCode: String
    let latitude: Double
    let longitude: Double
}
