// Generated from the owner's sea catalogue (bloom-ocean-names.txt), then filtered down to
// actual bodies of water. The source file mixed 268 islands in with the seas, and an island
// cannot carry this feature's wording: the first-claim notice says a workspace is the first to
// sail its name, and the map window is called Discovered Seas, neither of which survives
// "the Greenland". The words are the point, so the data was cut to fit them: seas, oceans and
// gulfs stay, land goes. Regenerate by replacing the string below with the source file's
// water rows; `OceanCatalog.parse` skips the header and drops any line that does not scan, so
// the data stays data and the rules stay in code. `Store` prunes unclaimed rows that a
// regeneration removed, and keeps claimed ones, so trimming this list is safe to do again.
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
"""
}
