# Rad na projektu

Aplikacija i zajednički engine imaju odvojene odgovornosti. Lokalna konfiguracija i sadržaj pripadaju aplikaciji; ponovljivo ponašanje pripada engine-u.

- Koristite izolovanu razvojnu i testnu bazu i Redis. Nikada ne testirajte produkcionim pristupnim podacima.
- Ne unosite lične podatke, tajne, razgovore građana ili stvarne izvoze u Git, testne primjere ili izvještaje.
- Primjeri moraju biti izmišljeni. Testovi ne smiju stvarno slati poruke.
- Čuvajte srpsku latinicu, srpsku ćirilicu, bosanski i hrvatski. Javnu dokumentaciju pišite srpskom latinicom.
- Pokrenite relevantne javne provjere prije slanja doprinosa. Održavalac provjerava PR lokalno; GitHub Actions nisu postupak verifikacije.
- Poštujte AGPL, tuđe licence i smjernice doprinosa. Bezbjednosne nalaze prijavite privatno na bojan@fondacijabijeljina.com.
