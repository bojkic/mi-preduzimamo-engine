# Obrada fotografija

Za obradu fotografija potrebni su Linux, ImageMagick 7.1.2-35 ili novija zakrpljena verzija 7.x sa JPEG/PNG/WebP koderima i podržanim `-limit` opcijama, te zaključana MiniMagick zavisnost. Provjerite verziju preko `magick -version` i `bundle exec ruby -rmini_magick -e 'puts MiniMagick.cli_version'`, iz okruženja stvarnog aplikacionog i worker procesa. Obrada i izrada umanjenih PNG/JPEG/WebP slika provjerene su sa 7.1.2-35. Provjeravajte i bezbjednosne objave za distribuciju i ugrađene biblioteke; granice dekodera ne zamjenjuju ažuriranje paketa. Nepodržan alat ili nedostajući koder uzrokuje odbijanje fotografije; prijava greške ne sadrži sadržaj slike ili izvorni naziv fajla.

Ulazni i izlazni fajl imaju granicu 5 MiB. Prihvata se jedan raster frejm, do 8192 piksela po dimenziji i do 32 miliona piksela ukupno. Animirane slike i veći rasterski prikazi se odbijaju. Aplikacija zadržava JPEG, PNG i statični WebP format, ispravlja orijentaciju i uklanja EXIF/GPS i druge metadata podatke prije čuvanja.

Stvarni broj pročitanih bajtova i MIME utvrđen iz sadržaja provjeravaju se prije dekodiranja. Dekoder dobija izričit JPEG/PNG/WebP naziv kodera i privatne putanje; korisnički naziv nije dio komandne putanje. Komande koriste niz argumenata, bez shell-a.

Provjera geometrije i konverzija dijele zidni rok od 8 sekundi. Svaki child ima CPU granicu 5 sekundi, adresni prostor do 1 GiB i pojedinačni fajl do 256 MiB. ImageMagick dobija jednog radnika, memory128MiB/map256MiB/disk256MiB i geometry/frame/time limite prije učitavanja slike. Stdout i stderr se čitaju ograničeno; stderr dekodera se ne objavljuje u logovima. Procesna grupa se zaustavlja pri isteku ili grešci, a privremeni pixel-cache direktorijum uklanja poslije obrade. Uspješan izlaz preuzima pozivalac, dok se neuspješni ulaz/izlaz odmah zatvaraju.

Ove granice važe za pojedinačnu obradu. Host i dalje obezbjeđuje ukupne CPU/memorijske limite, ograničenja broja zahtjeva, bezbjednu ImageMagick politiku, ažurirane biblioteke i monitoring. Ne mijenjajte globalni MiniMagick timeout ili sistemsku politiku tokom pojedinačnog zahtjeva.

Regresije su u `test/services/decidim/bih/media/image_decoder_test.rb` i `rails_test/image_normalizer_input_bounds_test.rb`. Pokrivaju male autorske slike, type/frame/geometry odbijanje, ograničen subprocess timeout/output i čišćenje, uz postojeće testove uklanjanja metadata. Prije primjene potrebne su i provjere svih proizvođača fotografija i propisani release gate za tačan par aplikacije i engine-a.

Ulaz i dalje mora imati tačno jedan frejm. ImageMagick konverzija dobija dva interna pixel-cache slota jer istovremeno drži prihvaćeni ulaz i izlaz; identify preflight ostaje na jednom slotu. To ne dopušta animirani ulaz i ne mijenja memory/map/disk, geometriju, byte ili CPU/zidni rok.
