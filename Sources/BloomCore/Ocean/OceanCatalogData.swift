// Generated from the owner's sea catalogue (bloom-ocean-names.txt), then filtered down to
// actual bodies of water. The source file mixed 268 islands in with the seas, and an island
// cannot carry this feature's wording: the first-claim notice says a workspace is the first to
// sail its name, and the map window is called Discovered Seas, neither of which survives
// "the Greenland". The words are the point, so the data was cut to fit them: seas, oceans and
// gulfs stay, land goes. Regenerate by replacing the string below with the source file's
// water rows; `OceanCatalog.parse` skips the header and drops any line that does not scan, so
// the data stays data and the rules stay in code. `Store` prunes unclaimed rows that a
// regeneration removed, and keeps claimed ones, so trimming this list is safe to do again.
// The rows after the Ambracian Gulf were added by hand, to make a full chart take longer: bays,
// straits, sounds and channels, every one a real body of water. `Store` seeds missing rows on
// every open, so adding to this list reaches databases that were seeded before it grew.
extension OceanCatalog {
    static let builtInTSV = """
name	slug	latitude	longitude
Adriatic Sea	adriatic-sea	43.000000	15.000000
Aegean Sea	aegean-sea	39.000000	25.000000
Alboran Sea	alboran-sea	36.000000	-3.000000
Amakusa Sea	amakusa-sea	32.333333	129.833333
Amundsen Sea	amundsen-sea	-73.000000	-112.000000
Andaman Sea	andaman-sea	10.000000	96.000000
Arabian Sea	arabian-sea	14.000000	65.000000
Arafura Sea	arafura-sea	-9.000000	133.000000
Archipelago Sea	archipelago-sea	60.300000	21.000000
Argentine Sea	argentine-sea	-46.000000	-63.000000
Ariake Sea	ariake-sea	32.906944	130.372222
Balearic Sea	balearic-sea	40.000000	1.500000
Bali Sea	bali-sea	-7.500000	115.500000
Baltic Sea	baltic-sea	58.000000	20.000000
Banda Sea	banda-sea	-6.000000	127.000000
Barents Sea	barents-sea	75.000000	40.000000
Beaufort Sea	beaufort-sea	72.000000	-137.000000
Bellingshausen Sea	bellingshausen-sea	-71.000000	-85.000000
Bering Sea	bering-sea	58.000000	-178.000000
Bismarck Sea	bismarck-sea	-4.000000	148.000000
Black Sea	black-sea	44.000000	35.000000
Bohol Sea	bohol-sea	9.200000	124.500000
Bothnian Sea	bothnian-sea	61.500000	19.500000
Camotes Sea	camotes-sea	10.500000	124.333333
Cantabrian Sea	cantabrian-sea	44.032300	-4.350600
Caribbean Sea	caribbean-sea	15.000000	-75.000000
Celebes Sea	celebes-sea	3.000000	122.000000
Celtic Sea	celtic-sea	50.000000	-8.000000
Seto Inland Sea	seto-inland-sea	34.166667	133.333333
Chukchi Sea	chukchi-sea	69.000000	-172.000000
Cooperation Sea	cooperation-sea	-65.000000	72.000000
Coral Sea	coral-sea	-18.000000	158.000000
Cosmonauts Sea	cosmonauts-sea	-65.000000	45.000000
Davis Sea	davis-sea	-66.000000	92.000000
East Siberian Sea	east-siberian-sea	72.000000	163.000000
Flores Sea	flores-sea	-7.040000	120.140000
Greenland Sea	greenland-sea	76.000000	-8.000000
Halmahera Sea	halmahera-sea	-1.000000	129.000000
Harima Sea	harima-sea	34.483333	134.600000
Hibiki Sea	hibiki-sea	34.000000	130.800000
Hiuchi Sea	hiuchi-sea	34.100000	133.300000
Ionian Sea	ionian-sea	38.000000	19.000000
Irish Sea	irish-sea	53.500000	-5.000000
Irminger Sea	irminger-sea	62.000000	-35.000000
Iroise Sea	iroise-sea	48.216667	-4.800000
Iyo Sea	iyo-sea	33.700000	132.400000
Java Sea	java-sea	-5.000000	110.000000
Kara Sea	kara-sea	77.000000	77.000000
Koro Sea	koro-sea	-18.000000	180.000000
Labrador Sea	labrador-sea	61.000000	-56.000000
Laccadive Sea	laccadive-sea	8.000000	75.000000
Laptev Sea	laptev-sea	76.000000	125.000000
Lazarev Sea	lazarev-sea	-68.000000	7.000000
Levantine Sea	levantine-sea	34.000000	34.000000
Ligurian Sea	ligurian-sea	43.500000	9.000000
Lincoln Sea	lincoln-sea	83.000000	-58.000000
Malin Sea	malin-sea	55.600000	-7.200000
Marmara Sea	marmara-sea	40.666667	28.000000
Mawson Sea	mawson-sea	-65.000000	105.000000
Mediterranean Sea	mediterranean-sea	35.000000	18.000000
Mindanao Sea	mindanao-sea	9.200000	124.500000
Molucca Sea	molucca-sea	-0.416667	125.416667
Myrtoan Sea	myrtoan-sea	37.000000	24.000000
Natuna Sea	natuna-sea	1.000000	107.000000
North Sea	north-sea	56.000000	3.000000
Norwegian Sea	norwegian-sea	69.000000	2.000000
Okhotsk Sea	okhotsk-sea	55.000000	150.000000
Pechora Sea	pechora-sea	69.750000	54.000000
Philippine Sea	philippine-sea	20.000000	130.000000
Red Sea	red-sea	22.000000	38.000000
Ross Sea	ross-sea	-75.000000	-175.000000
Salish Sea	salish-sea	48.936667	-123.061111
Samar Sea	samar-sea	11.825000	124.500000
Sargasso Sea	sargasso-sea	28.000000	-66.000000
Savu Sea	savu-sea	-9.750000	122.000000
Scotia Sea	scotia-sea	-57.500000	-40.000000
Seram Sea	seram-sea	-2.333333	128.000000
Sibuyan Sea	sibuyan-sea	12.666667	122.500000
Solomon Sea	solomon-sea	-8.000000	154.000000
Somali Sea	somali-sea	5.000000	52.000000
Somov Sea	somov-sea	-67.000000	160.000000
Sulu Sea	sulu-sea	8.000000	120.000000
Suo Sea	suo-sea	33.819847	131.514914
Tasman Sea	tasman-sea	-40.000000	160.000000
Thracian Sea	thracian-sea	40.366667	25.166667
Timor Sea	timor-sea	-10.000000	127.000000
Tyrrhenian Sea	tyrrhenian-sea	40.000000	12.000000
Visayan Sea	visayan-sea	11.500000	123.666667
Wandel Sea	wandel-sea	82.250000	-17.000000
Weddell Sea	weddell-sea	-75.000000	-45.000000
White Sea	white-sea	65.500000	37.500000
Yellow Sea	yellow-sea	38.000000	123.000000
Pacific Ocean	pacific-ocean	0.000000	-160.000000
Atlantic Ocean	atlantic-ocean	0.000000	-25.000000
Indian Ocean	indian-ocean	-20.000000	80.000000
Southern Ocean	southern-ocean	-65.000000	90.000000
Arctic Ocean	arctic-ocean	90.000000	0.000000
Gulf of Mexico	gulf-of-mexico	25.000000	-90.000000
Persian Gulf	persian-gulf	26.000000	52.000000
Gulf of Aden	gulf-of-aden	12.000000	48.000000
Gulf of Oman	gulf-of-oman	25.000000	58.000000
Gulf of Alaska	gulf-of-alaska	58.600000	-145.200000
Gulf of California	gulf-of-california	28.000000	-112.000000
Gulf of Guinea	gulf-of-guinea	0.000000	0.000000
Gulf of Bothnia	gulf-of-bothnia	63.000000	20.000000
Gulf of Finland	gulf-of-finland	59.833333	26.000000
Gulf of Riga	gulf-of-riga	57.750000	23.500000
Gulf of Thailand	gulf-of-thailand	9.500000	102.000000
Gulf of Tonkin	gulf-of-tonkin	19.750000	107.750000
Gulf of Aqaba	gulf-of-aqaba	28.750000	34.750000
Gulf of Suez	gulf-of-suez	28.750000	33.000000
Gulf of Carpentaria	gulf-of-carpentaria	-14.000000	139.000000
Gulf of Venezuela	gulf-of-venezuela	11.500000	-71.000000
Gulf of Kutch	gulf-of-kutch	22.600000	69.500000
Gulf of Khambhat	gulf-of-khambhat	21.500000	72.500000
Gulf of Mannar	gulf-of-mannar	8.470000	79.020000
Gulf of Gabes	gulf-of-gabes	34.000000	10.416667
Gulf of Sidra	gulf-of-sidra	31.500000	18.000000
Gulf of Antalya	gulf-of-antalya	36.500000	31.000000
Gulf of Lion	gulf-of-lion	42.996389	4.000278
Gulf of Corinth	gulf-of-corinth	38.200000	22.500000
Gulf of Patras	gulf-of-patras	38.250000	21.500000
Gulf of Taranto	gulf-of-taranto	39.885000	17.276944
Gulf of Tunis	gulf-of-tunis	37.000000	10.500000
Gulf of Izmir	gulf-of-izmir	38.483333	26.816667
Gulf of Saros	gulf-of-saros	40.550000	26.460000
Gulf of Burgas	gulf-of-burgas	42.500000	27.583333
Gulf of Anadyr	gulf-of-anadyr	64.000000	-178.000000
Gulf of Ob	gulf-of-ob	68.833333	73.500000
Saronic Gulf	saronic-gulf	37.700000	23.600000
Thermaic Gulf	thermaic-gulf	40.250000	22.833333
Ambracian Gulf	ambracian-gulf	38.972500	20.969167
Albemarle Sound	albemarle-sound	36.050000	-76.000000
Algoa Bay	algoa-bay	-33.900000	25.900000
Amundsen Gulf	amundsen-gulf	70.600000	-122.000000
Antarctic Sound	antarctic-sound	-63.400000	-56.500000
Baffin Bay	baffin-bay	73.000000	-67.000000
Bass Strait	bass-strait	-39.500000	145.500000
Bay of Bengal	bay-of-bengal	15.000000	88.000000
Bay of Biscay	bay-of-biscay	45.000000	-4.000000
Bay of Campeche	bay-of-campeche	19.800000	-93.500000
Bay of Fundy	bay-of-fundy	45.000000	-66.000000
Bay of Islands	bay-of-islands	-35.200000	174.200000
Bay of Kotor	bay-of-kotor	42.450000	18.650000
Bay of Plenty	bay-of-plenty	-37.500000	177.000000
Bering Strait	bering-strait	65.800000	-168.900000
Bight of Benin	bight-of-benin	5.500000	3.000000
Bight of Bonny	bight-of-bonny	3.000000	8.000000
Bosphorus Strait	bosphorus-strait	41.120000	29.070000
Botany Bay	botany-bay	-34.000000	151.200000
Bothnian Bay	bothnian-bay	64.800000	22.500000
Bransfield Strait	bransfield-strait	-63.000000	-59.000000
Bristol Bay	bristol-bay	58.000000	-159.000000
Bristol Channel	bristol-channel	51.400000	-3.800000
Cabot Strait	cabot-strait	47.400000	-59.800000
Chesapeake Bay	chesapeake-bay	38.000000	-76.200000
Cook Strait	cook-strait	-41.300000	174.400000
Coronation Gulf	coronation-gulf	68.100000	-112.000000
Davao Gulf	davao-gulf	6.800000	125.800000
Davis Strait	davis-strait	65.000000	-58.000000
Delagoa Bay	delagoa-bay	-25.900000	32.900000
Delaware Bay	delaware-bay	39.100000	-75.200000
Denmark Strait	denmark-strait	66.500000	-27.000000
Disko Bay	disko-bay	69.250000	-52.000000
Doubtful Sound	doubtful-sound	-45.300000	166.900000
Drake Passage	drake-passage	-58.000000	-65.000000
English Channel	english-channel	50.000000	-1.000000
False Bay	false-bay	-34.200000	18.600000
Great Australian Bight	great-australian-bight	-34.000000	131.000000
Guanabara Bay	guanabara-bay	-22.800000	-43.150000
Gulf of Boothia	gulf-of-boothia	71.000000	-91.000000
Gulf of Cadiz	gulf-of-cadiz	36.500000	-7.000000
Gulf of Chiriqui	gulf-of-chiriqui	8.000000	-82.200000
Gulf of Darien	gulf-of-darien	9.000000	-77.200000
Gulf of Fonseca	gulf-of-fonseca	13.150000	-87.700000
Gulf of Gdansk	gulf-of-gdansk	54.500000	19.000000
Gulf of Genoa	gulf-of-genoa	44.200000	8.800000
Gulf of Gonave	gulf-of-gonave	18.800000	-73.300000
Gulf of Guayaquil	gulf-of-guayaquil	-3.000000	-80.500000
Gulf of Hammamet	gulf-of-hammamet	36.200000	10.700000
Gulf of Honduras	gulf-of-honduras	16.200000	-88.000000
Gulf of Maine	gulf-of-maine	43.000000	-68.500000
Gulf of Martaban	gulf-of-martaban	16.000000	96.800000
Gulf of Naples	gulf-of-naples	40.750000	14.250000
Gulf of Nicoya	gulf-of-nicoya	9.800000	-84.800000
Gulf of Panama	gulf-of-panama	8.400000	-79.000000
Gulf of Paria	gulf-of-paria	10.500000	-62.200000
Gulf of Penas	gulf-of-penas	-47.300000	-75.000000
Gulf of Saint Lawrence	gulf-of-saint-lawrence	48.000000	-62.000000
Gulf of San Jorge	gulf-of-san-jorge	-46.000000	-66.000000
Gulf of San Matias	gulf-of-san-matias	-41.600000	-64.300000
Gulf of Tadjoura	gulf-of-tadjoura	11.700000	43.000000
Gulf of Tehuantepec	gulf-of-tehuantepec	15.500000	-95.000000
Gulf of Tomini	gulf-of-tomini	-0.500000	121.000000
Gulf of Trieste	gulf-of-trieste	45.600000	13.600000
Gulf of Valencia	gulf-of-valencia	39.600000	0.200000
Gulf St Vincent	gulf-st-vincent	-35.000000	138.100000
Ha Long Bay	ha-long-bay	20.900000	107.100000
Hangzhou Bay	hangzhou-bay	30.400000	121.300000
Hauraki Gulf	hauraki-gulf	-36.500000	175.100000
Hawke Bay	hawke-bay	-39.400000	177.200000
Hudson Bay	hudson-bay	60.000000	-85.000000
Hudson Strait	hudson-strait	62.000000	-70.000000
Ise Bay	ise-bay	34.700000	136.800000
James Bay	james-bay	53.500000	-80.500000
Joseph Bonaparte Gulf	joseph-bonaparte-gulf	-14.300000	128.800000
Kandalaksha Gulf	kandalaksha-gulf	66.500000	33.500000
Kattegat Strait	kattegat-strait	57.000000	11.300000
Kerch Strait	kerch-strait	45.300000	36.500000
Korea Bay	korea-bay	39.000000	124.000000
Korea Strait	korea-strait	34.500000	129.000000
Kotzebue Sound	kotzebue-sound	66.700000	-162.500000
Lancaster Sound	lancaster-sound	74.200000	-84.000000
Leyte Gulf	leyte-gulf	10.800000	125.400000
Liaodong Bay	liaodong-bay	40.300000	121.200000
Lingayen Gulf	lingayen-gulf	16.200000	120.200000
Lombok Strait	lombok-strait	-8.500000	115.800000
Long Island Sound	long-island-sound	41.100000	-72.800000
Luzon Strait	luzon-strait	20.500000	121.000000
Makassar Strait	makassar-strait	-2.000000	118.000000
Manila Bay	manila-bay	14.500000	120.750000
McMurdo Sound	mcmurdo-sound	-77.500000	165.000000
Milford Sound	milford-sound	-44.600000	167.900000
Mona Passage	mona-passage	18.500000	-67.900000
Monterey Bay	monterey-bay	36.800000	-121.900000
Moreton Bay	moreton-bay	-27.300000	153.300000
Mozambique Channel	mozambique-channel	-19.000000	41.000000
North Channel	north-channel	55.200000	-5.500000
Norton Sound	norton-sound	64.000000	-163.000000
Oresund Strait	oresund-strait	55.800000	12.800000
Palk Strait	palk-strait	10.000000	79.700000
Peter the Great Gulf	peter-the-great-gulf	42.800000	132.000000
Port Phillip Bay	port-phillip-bay	-38.100000	144.800000
Prince William Sound	prince-william-sound	60.700000	-147.000000
Puget Sound	puget-sound	47.700000	-122.400000
Queen Maud Gulf	queen-maud-gulf	68.500000	-102.000000
Saint George's Channel	saint-georges-channel	52.000000	-6.000000
San Francisco Bay	san-francisco-bay	37.700000	-122.300000
Sea of Azov	sea-of-azov	46.000000	36.500000
Sea of Crete	sea-of-crete	35.700000	25.000000
Sea of Japan	sea-of-japan	40.000000	135.000000
Sea of the Hebrides	sea-of-the-hebrides	57.200000	-6.800000
Shark Bay	shark-bay	-25.500000	113.500000
Shelikhov Gulf	shelikhov-gulf	60.000000	156.000000
Skagerrak Strait	skagerrak-strait	57.800000	9.000000
Spencer Gulf	spencer-gulf	-34.000000	137.000000
Strait of Dover	strait-of-dover	51.000000	1.500000
Strait of Gibraltar	strait-of-gibraltar	35.950000	-5.600000
Strait of Hormuz	strait-of-hormuz	26.600000	56.400000
Strait of Magellan	strait-of-magellan	-53.500000	-70.500000
Strait of Malacca	strait-of-malacca	4.000000	99.500000
Strait of Messina	strait-of-messina	38.250000	15.600000
"""
}
