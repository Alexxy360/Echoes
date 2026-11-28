# Seria R-03b — najwyżej dwie próby plików w jednym oknie

**Seria zakończona; dwa inwentarze zużyte. Drugi przyjęty w całości, oba cleanup potwierdzone. Brak dalszych prób w tym budżecie.** [Wynik poprzedniej próby](WYNIK_PIERWSZEJ_PROBY_PLIKOW_DEVELOPMENT.md): oba uploady przyjęte, przypięcie HTTP 400, sprzątanie rekordów potwierdzone. Zużytego inwentarza nie ponawiamy.

Kontrakt SHA-256: **86327f1d532d5e757790fb930e976d0c321debc7aeb0442013926209d4dfdea1**. Dwa odrębne inwentarze:

| Próba | SHA-256 |
| --- | --- |
| 1 | 21f2bb4e14eb6fecada386b5f261fbad873b75051f0cf00fd6b3734a9c549de6 |
| 2 | 08a807146a5abc40d2f4936fb9d3da52140205264d7756356d08537a0c9a1d82 |

Wyłącznie publiczne CloudKit **Development**, `iCloud.mpvEcho.Echo`, zespół `22YC9RAP4P`, schemat SHA `495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543`. Ten sam istniejący lokalny klucz administratora: „Echoes Community Development 2026-11-19”, ID `e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10`, SPKI SHA `dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60`. Zachowuje prawa administratora publicznego Development także poza 3 km. Bez nowego klucza zarejestrowanego w Apple, roli, schematu lub transferu PEM do hostingu.

## Wspólny budżet

Najwyżej **2 próby**, każda na dwóch własnych nowych losowych rekordach (`EchoesAvatarV1` i izolowany `EchoesRegistryCheckpointV1`). **Jedno wspólne okno do 30 minut**, nie 30 minut na próbę. Zatrzymanie po pierwszym sukcesie z poprawnym sprzątaniem; także zatrzymanie, gdy wcześniejsze IO lub sprzątanie nie zostały potwierdzone. Nie uruchamiamy prób równolegle.

Łącznie najwyżej **128 żądań API Apple, 4 uploady, 4 pobrania, 5506 B wysłanych obrazów**. Każda próba: do 64 API (w tym 2 granty, CAS i cleanup), po jednym uploadzie/pobraniu każdego wariantu. Dwa generowane gradienty mają 1649 B (192×96, SHA9c67d12f…) i 1104 B (128×64, SHA6462e704…), razem 2753 B na próbę; te same bajty są odtwarzane istniejącym kodekiem i związane pełnymi manifestami z każdym dokładnym inwentarzem. Bez zdjęcia osoby lub EXIF. API JSON do 16 KiB/64 fragmentów, operacje do 8 s.

Przebieg każdej próby odpowiada [szczegółowemu zakresowi plików](ZAKRES_PROBY_PLIKOW_DEVELOPMENT.md): własny preflight NOT_FOUND, bootstrap izolowanego checkpointu, istniejące kodeki/rejestr/SQLite/assets/repository, granty i dokładne uploady, create i lookup z manifestami/commitmentami, odmowa starego CAS, bounded download z SHA, świeże warunkowe delete własnych create-intentów i końcowe NOT_FOUND. Bez globalnego checkpointu, query, force operacji albo publikacji profilu.

Jeśli pierwsza próba nie przejdzie, a sprzątanie i odpływ konkretnego IO są potwierdzone, budżet obejmuje lokalną poprawkę **formatu/projekcji pól, parsera lub diagnostyki**, jej odpowiednie testy i aktualizację sprawdzonego commitu przed drugą próbą. Nie obejmuje zmiany odbiorców, uprawnień, typów/pól rekordu, listy dwóch inwentarzy, treści/rozmiaru obrazów lub limitów. Po wyczerpaniu budżetu/okna stop; nie resetujemy attempt ani okna. Właściciel może ograniczyć zgodę do jednej próby.

## Odbiorcy i ochrona danych

API tylko `api.apple-cloudkit.com`, stałe Development/public `assets/upload`, `records/lookup`, `records/modify`. Upload tylko zaobserwowany `cws.icloud-content.com`. Pobranie tylko z własnej projekcji rekordu i z góry wskazanych kandydatów `cws.icloud-content.com` lub `cvws.icloud-content.com`; nie są jeszcze potwierdzoną listą hostów Runtime. Bez wildcard, poszerzania listy i przekierowań. Żaden podpis S2S, bearer lub cookie nie trafia do serwera pliku. Udokumentowany końcowy segment `${f}` może być zastąpiony stałym avatar.jpg przy identycznym query.

Trwałe intenty przed żądaniami, jedna rezerwacja na inwentarz. Prywatny operator wymaga konkretnej zgody i limitu 1–2, wspólnego zegara wall/monotonic, zgodności źródeł/HEAD, zakończenia poprzedniego procesu i potwierdzenia cleanup. Zapisuje tylko zamkniętą diagnostykę; rawURL, podpisy, reason, body i receipty nie trafiają do raportów. Receipty są szyfrowane lokalnym technicznym kluczem w prywatnym SQLite poza Git. Przy awarii lub wygaśnięciu zachowujemy dokładną niepewność/inwentarz; osobne odzyskiwanie nie wynika z resetu tej serii. Potwierdzenie NOT_FOUND rekordu nie dowodzi fizycznego wymazania pliku lub unieważnienia starego adresu Apple/CDN; nieprzypięte pliki mogą pozostać u dostawcy.

**Bez danych użytkowników, prywatnych profili/bazy, telefonu, GPS/Muzyki, SIWA, Cloudflare/hostingu/transferu PEM, nowych praw, Production, Firebase, TestFlight i opłat.** To odbiór transportu plików z lokalną syntetyczną tożsamością, nie pełnej autoryzacji sesji, publikacji, 3 km albo A/B.

[Dowody przygotowania](evidence/avatar-asset-wire-batch-preparation.json): dwa rzeczywiste lokalne prepare/inspect bez sieci, materiały 0700/0600 poza Git; operator skompilowany i sprawdzona odmowa bez zgody. Pełna maszyna awarii prywatnego operatora nie jest lokalnie przetestowana. Kod CLI/komponentów ma 1014/1014 testów na obu Node; nowej serii nie uruchomiono i nie rozpoczęto okna. Przed i po każdym przebiegu operator sprawdzi źródła i zapisze rzeczywisty wynik. Źródło formatu assetów: [Apple Uploading Assets](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/UploadAssets.html).

## Wykonanie po uzyskaniu zgody

Właściciel „zgadzam sie” zatwierdził limit2. Pierwszy inwentarz wykonano; create przyjęty, odczyt odmówiony przez ASSETID. Serię wstrzymano. Cleanup dokładnie tych samych rekordów zakończono osobno w tym samym oryginalnym oknie i pierwszym budżecie:29/64API łącznie, oba ID NOT_FOUND,0pending. Pierwotny raport nie został nadpisany, operator sprawdza dodatkowy dowód i jego budżet/termin. [Bieżący wynik](WYNIK_SERII_PLIKOW_DEVELOPMENT.md). Drugi inwentarz jeszcze niewykonany; nie rozpoczyna się nowego okna.

Końcowy [wynik](WYNIK_SERII_PLIKOW_DEVELOPMENT.md):65API/4uploady/2pobrania, drugi protokół przyjęty, wszystkiepermity usunięte,0pending. Nie resetować okna lub inwentarzy.
