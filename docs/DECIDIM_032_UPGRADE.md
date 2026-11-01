# Prelazak na Decidim 0.32

BIH 0.4.0 cilja Decidim 0.32.2, Rails 8.1 i Ruby 3.4 (najmanje 3.4.12). Referentna aplikacija zaključava konkretne verzije zavisnosti. Prije produkcione nadogradnje sačuvajte bazu, privatne fajlove i postojeće ključeve; promjena `SECRET_KEY_BASE` nije dio ove nadogradnje. Pratite i zvanična uputstva za sve prelazne verzije Decidim-a.

## Sačuvajte članstva prije brisanja stare tabele

Decidim 0.32 uklanja `decidim_user_group_memberships`. BIH još koristi ta članstva za ovlašćenja upravljanja grupama i prenos bodova. Migracija `20261101090000_preserve_goodwill_group_memberships.rb` kopira identifikatore, članove, grupe, uloge i vremenske oznake u `decidim_bih_goodwill_group_memberships`, provjerava broj redova i nastavlja sekvencu identifikatora. Model `Goodwill::GroupMembership` zatim koristi novu tabelu.

**Postojeća instalacija:** ova migracija mora biti izvršena prije upstream migracije `RemoveUserGroupMemberships`. Referentni host čuva taj redoslijed. Ako drugi host kopira ili mijenja vremenske oznake migracija, provjerite stvarni redoslijed; po potrebi prvo izvršite samo migraciju očuvanja preko `bin/rails db:migrate:up VERSION=20261101090000`, dok stara tabela još postoji. Engine mora biti u Rails migration paths. Ne kopirajte iste engine migracije pod novim verzijama ako ih host već učitava direktno.

**Nova instalacija:** nova tabela se pravi i kad stara tabela ne postoji. To nije dokaz da su prethodno obrisana članstva obnovljena. Ako je upstream brisanje već izvršeno nad postojećim podacima bez očuvanja, potreban je pregled i oporavak iz odgovarajuće rezervne kopije. `down` namjerno ne briše sačuvana ovlašćenja.

## Ostale promjene

- Izvorni homepage blok `global_menu` više nije u Decidim-u. BIH čuva kompatibilni cell, registraciju bloka i oznake za `sr`, `sr-Cyrl`, `bs` i `hr`. Autorska/licencna napomena je u `lib/decidim/bih/licenses/decidim-global-menu-NOTICE.txt`.
- Decidim-ov `mailer_reply` setter je uklonjen. Opciona BIH postavka `mailer_reply_to` i dalje određuje nadgledano sanduče za odgovore i čuva eksplicitni Reply-To pojedinačne poruke. Ne podešena adresa ostaje prazna.
- Core putanje imaju prefiks jezika. `Decidim::Bih::LocalePath.strip` služi za ujednačeno poređenje putanja u pravilima privatnosti i ograničenjima zahtjeva; ne prepisuje stvarni HTTP zahtjev.
- Rails koristi Vips za standardne varijante slika. BIH ograničeni `Media::ImageDecoder` i dalje ima zasebne zahtjeve i bezbjednosne granice opisane u `MEDIA_DECODING.md`.

Lokalno pokretanje, migracija sintetičkih podataka i provjera prikaza ne potvrđuju isporuku poruka spoljnog provajdera ili prijem na uređaju. Ne koristite produkcione podatke ili pristupne podatke u razvojnim provjerama.
