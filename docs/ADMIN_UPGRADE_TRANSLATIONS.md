# Prevodi administracije poslije Decidim 0.32 nadogradnje

Pregled 2026-11-02 obuhvata dashboard, listu procesa, novi proces i administratorske uslove na `sr`, `sr-Cyrl`, `bs` i `hr`. Ne potvrđuje prevod čitave administracije.

Uzrok nedostajućeg naslova bio je promijenjen upstream ključ (`dashboard.show.title` i `admin_terms.show.title`). Datum koristi novi Stimulus/wc-datepicker tok: nedostajali su rječnici formata, redoslijeda, separatora i dugmadi. Dodati su u `config/locales/admin_upgrade.*.yml`; nisu mijenjane biblioteke niti zaobilazna JS logika.

Inventar stvarno renderovanih ruta pronašao je 107 različitih ključeva sa engleskim fallback-om u najmanje jednom jeziku, ukupno 687 kombinacija ključ/jezik/ruta. Dopunjeni su samo nedostajući izvorni prevodi: sr 97, sr-Cyrl 107, bs 97, hr 107. Postojeći izvorni prevodi nisu prepisivani. Ponovljeno mjerenje istih 16 ruta našlo je 0 takvih kombinacija. Dodatna provjera izvornog prevoda pronašla je i devet ćiriličnih oznaka sa latiničnim fallback-om; i one su dopunjene. To ne znači da su nazivi proizvoda, uneseni sadržaji ili svi drugi administrativni tokovi prevedeni.

Ciljane request provjere pokrivaju prikaz naslova, format datuma i nekoliko važnih oznaka bez engleskog fallback-a. Browser provjera pokriva dashboard i stvarni unos `15.12.2026`, vrijednost izvornog polja `2026-12-15`, otvaranje i zatvaranje kalendara na sva četiri jezika. Rezultati različitih commitova i okruženja bilježe se odvojeno.

## Inventar dopunjenih ključeva

| Ključ | Jezici koji su koristili engleski fallback |
|---|---|
| `activemodel.attributes.editor_image.file` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.description` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.developer_group` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.end_date` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.has_members` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.hero_image` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.local_area` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.meta_scope` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.participatory_process_group_id` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.participatory_scope` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.participatory_structure` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.promoted` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.related_process_ids` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.short_description` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.slug` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.start_date` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.subtitle` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.target` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.title` | bs, hr, sr, sr-Cyrl |
| `activemodel.attributes.participatory_process.weight` | bs, hr, sr, sr-Cyrl |
| `activerecord.models.decidim/participatory_process` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.actions.import_process` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.actions.new_process` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.actions.view_deleted_processes` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.filters.decidim_participatory_process_group_id_eq.label` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.filters.filter_label` | hr, sr-Cyrl |
| `decidim.admin.filters.published_at_null.label` | hr |
| `decidim.admin.filters.published_at_null.values.false` | hr |
| `decidim.admin.filters.published_at_null.values.true` | hr |
| `decidim.admin.filters.with_any_access_mode.label` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.filters.with_any_access_mode.values.open` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.filters.with_any_access_mode.values.restricted` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.filters.with_any_access_mode.values.transparent` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.menu.admin_log` | hr |
| `decidim.admin.menu.decidim_awesome` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.menu.insights` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.menu.manage` | hr |
| `decidim.admin.menu.newsletters` | hr |
| `decidim.admin.menu.participatory_process_groups` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.menu.settings` | hr |
| `decidim.admin.menu.static_pages` | hr |
| `decidim.admin.menu.users` | hr |
| `decidim.admin.models.participatory_process.fields.access_mode` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.models.participatory_process.fields.actions` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.models.participatory_process.fields.created_at` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.models.participatory_process.fields.published` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.models.participatory_process.fields.title` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.participatory_processes.index.access_modes.open` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.participatory_processes.index.access_modes.restricted` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.participatory_processes.index.access_modes.transparent` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.participatory_processes.new.create` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.titles.panel` | bs, hr, sr, sr-Cyrl |
| `decidim.admin.tooltips.deleted_processes_info` | bs, hr, sr, sr-Cyrl |
| `decidim.blogs.models.post.fields.official_blog_post` | bs, hr, sr, sr-Cyrl |
| `decidim.decidim_awesome.config.intergram.auto_no_response` | bs, hr, sr, sr-Cyrl |
| `decidim.decidim_awesome.config.intergram.auto_response` | bs, hr, sr, sr-Cyrl |
| `decidim.decidim_awesome.config.intergram.intro_message` | bs, hr, sr, sr-Cyrl |
| `decidim.decidim_awesome.config.intergram.title_closed` | bs, hr, sr, sr-Cyrl |
| `decidim.decidim_awesome.config.intergram.title_open` | bs, hr, sr, sr-Cyrl |
| `decidim.editor_images.drag_and_drop_help` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.file_help.image.message_1` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.file_help.image.message_2` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.add_image` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.edit_image` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.error` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.filename` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.remove` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.replace` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.save` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.title` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.title_required` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.uploaded` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.validating` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.labels.validation_error` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload.select_file` | bs, hr, sr, sr-Cyrl |
| `decidim.forms.upload_help.dropzone` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.access.label` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.access.options.open` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.access.options.restricted` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.access.options.transparent` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.access.set_this_space_as` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.define_taxonomy_filters` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.duration` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.has_members_help` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.images` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.metadata` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.no_taxonomy_filters_found` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.related_processes` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.select_process_group` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.taxonomies` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.title` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.form.visibility` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.index.title` | bs, hr, sr, sr-Cyrl |
| `decidim.participatory_processes.admin.participatory_processes.new.title` | bs, hr, sr, sr-Cyrl |
| `decidim.shared.confirm_modal.close_modal` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.amendments` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.autosaved_error` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.autosaved_retrieved` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.autosaved_success` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.awesome_authorization_groups_placeholder` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.drag_and_drop_image` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.hashtags` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.items` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.meetings` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.proposals` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.select_deselect_all` | bs, hr, sr, sr-Cyrl |
| `layouts.decidim.decidim_awesome.awesome_config.taxonomies` | bs, hr, sr, sr-Cyrl |

## Dopuna nakon nezavisne RC4 probe — 3. novembar 2026.

Raniji inventar ruta nije obuhvatio nedostajuće aria oznake date polja i latinične nazive mjeseci u widgetu. Novi DatePickerLabels proširuje i date i datetime polja uz očuvanje postojećih data/controller atributa; widget tekstovi su dati na sva četiri jezika. Referentni host u svom core pack proširenju uvozi `src/decidim/bih/calendar_locale`; taj engine modul traži `sr-Latn` samo za kalendare sr stranica, bez mijenjanja jezika ruta ili drugih locale-a. Dodati su i ključevi za phases navigaciju i about polja.

Nove standalone provjere oznaka i JavaScript ponašanja prolaze. Stvarni prikaz novog kandidata, ARIA atributi i mjeseci u browser-u još traže novu render/browser provjeru; raniji browser rezultat se ne prenosi na ovaj kod. Operatorovi tekstovi poput sadržaja administratorskih uslova ostaju lokalni sadržaj i ne prepisuju se prevodima.

## RC5 nalaz i naredna objedinjena popravka

Nezavisni rc5 browser izvještaj potvrđuje uklonjene undefined ARIA oznake i latinične sr mjesece, ali Bosnian ICU izlaz je M01–M12/Sun–Sat, a unutrašnji wc-datepicker labels ostaju engleski. Adapter sada čeka Stencil definiciju/hidrataciju i postavlja podržani labels objekat za sr/sr-Cyrl/bs/hr. Bosanski prikaz dobija lokalna imena i pristupačne opise kroz scoped light DOM, uključujući ponovni render i ponedjeljak kao prvi dan. Mijenjaju se samo tekst/oznaka: vrijednosti datuma, događaji i globalni Intl ostaju isti. Postojeći tekst čvorovi se čuvaju radi Stencil virtual DOM reference; upisi se izvršavaju samo kada se tekst razlikuje da observer ne napravi petlju. Nove standalone probe provjeravaju ove granice; stvarni kompajlirani browser rezultat narednog kandidata još nedostaje.

Isti rc5 izvještaj otkrio je protivrječan status e-maila i razliku sažetak/timeline vremena. AccountSummary sada koristi EmailConfirmation dokaz trenutne adrese kao postojeći panel, a javni report prikaz eksplicitno koristi konfiguracionu aplikacionu vremensku zonu. Pripremljene su regresije za stvarni tok dokazivanja/promjene e-maila i zimski/ljetni/prelaz-dana render. Bez njihovog izvršenja ne označavati cijeli UI provjerenim.
