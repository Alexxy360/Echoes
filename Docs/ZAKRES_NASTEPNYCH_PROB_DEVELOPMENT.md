# Następne próby CloudKit Development — R-02 / R-03a

**Przygotowane lokalnie, niezatwierdzone i niewykonane.** Logowanie i sprzątanie R-04c.1b zaliczone w `eee34f7` ([wynik](PIERWSZA_PROBA_LOGOWANIA_WYNIK.md)). Jeden zakres obejmuje dwa odrębne wykonania istniejących narzędzi:

| Próba | Nowy dokładny inwentarz SHA-256 | Limit i operacje |
| --- | --- | --- |
| R-02 — zapytania mapy/czatu | `54a7a6eba5d08808695897c7a8aea6464d78bc2a02b6658ebd0ba83777317b05` | Do30min / do32wywołań razem ze sprzątaniem. Dokładny lookup12ID, najwyżej1batch create6syntetycznych obecności i6wiadomości, odczyt własnych pól, NEAR/filter/sort/continuation wyłącznie we własnych6ID typu (strony po2, do6stron/typ). Świeży lookup, warunkowe delete tylko zgodnych własnych rekordów z aktualnym tagiem i sprawdzenie nieobecności |
| R-03a — hosty uploadu zdjęć | `68595368b901c87add1cf25631a55d991b8651dcaf072698d4803f5bae3dcb7f` | Odrębne okno do30min / najwyżej1request assets/upload do api.apple-cloudkit.com, pola image i thumbnail jednego losowego EchoesAvatarV1. Zapis tylko pełnych zweryfikowanych hostów/przypisania. Bez uploadu obrazu, otwierania URL, zapisu lub usunięcia rekordu |

Cel obu prób: publiczna baza **CloudKit Development**, `iCloud.mpvEcho.Echo`, zespół `22YC9RAP4P`, schemat SHA `495cdbdc95308a0d88b6b0e2d73b8d3bae7f5988aad1acac24e13f3cf4d01543`. Stałe współrzędne0/0 lub1/1 są syntetyczne, bez GPS telefonu.

Wyłącznie istniejący lokalny klucz **Echoes Community Development 2026-11-19**, ID `e601721628f60c732d866bf669dcea4c2dfc7e99cb7dc9f68643a5a778330b10`, SPKI SHA `dff346013b6931700abe67b7b2358fcd2f36c8c9dd22481dbadbae9f5b9aee60`. Lokalny odcisk, metadata zespołu/kontenera/Development i0600 potwierdzone. Istniejące uprawnienia administratora obejmują publiczne Development również poza3km. Nie nadajemy nowych praw, nie tworzymy kluczy i nie przekazujemy tego klucza Cloudflare. To nie jest klucz Sign in with Apple.

Po konkretnej zgodzie każda próba otrzyma własny jednorazowy permit i świeże okno. Bez przedłużania okien, retry requestu R-03a i ponownego run R-02. Kolizja zatrzymuje create. Obcy ID/pole, błąd indeksu lub niepełny wynik oznaczają niezaliczenie; nie usuwamy ograniczenia do własnych ID. Cleanup tylko zgodnych własnych danych w ważnym oknie; bez force-delete. Pending po błędzie/upływie czasu pozostaje jawnie w journalu i wymaga osobnego zakresu cleanup. Grant może czasowo istnieć u Apple także po niepewnym request, bez utworzenia obrazu/rekordu.

Mechanika i dalsze ograniczenia pozostają zgodne z [R-02](ZAKRES_PROBY_ZAPYTAN_DEVELOPMENT.md) i [R-03a](PROBA_GRANTOW_ZDJEC_DEVELOPMENT.md). Ten dokument zastępuje ich dawne SHA inwentarzy, bez rozszerzenia operacji. Stare katalogi tymczasowe utraciły inventory.json; nie wykorzystujemy dawnych inwentarzy lub zgód. Niezmienione prepare/inspect utworzyły nowe pliki0700/0600, query revision0/state null, bez permitów, rezerwacji, attempt i sieci. Osobna lokalna kontrola klucza nie wykonywała sieci. [Dowód](evidence/next-development-trials-preparation.json).

Bez prawdziwych kont/profili, lokalizacji/Muzyki, obrazów/ASSET bytes/CDN, telefonu, hostingu lub sekretów w Cloudflare, zmian schematu/uprawnień, Production, Firebase, TestFlight i opłat. Jedynym odbiorcą jest dotychczasowe Apple CloudKit Development. Bez sekretów i surowych URL grantów w Git. Cloudflare po poprzedniej próbie pozostaje wyłączony i bez aktywnych sekretów.

Nie zmieniano kodu narzędzi ani nie ponawiano niezmienionych testów/kompilacji. Ich wcześniejsze14i8testów na obu Node są opisane w poprzednich raportach; bieżące prepare/inspect wykonano na Node24.22.3. Te ograniczone próby nie zastępują pełnego R-02/R-03, zwykłego A/B, rzeczywistego uploadu obrazów ani gotowości TestFlight.

## Kontrola zgody po wznowieniu celu

Automatyczna kontrola zatwierdzania odrzuciła uruchomienie R-02 przed wykonaniem polecenia: wznowienie celu nie potwierdziło tego konkretnego zakresu użycia klucza oraz zapisu/usunięcia rekordów. Ponowny odczyt katalogów potwierdził brak permitów, attempt i logu wykonania obu prób. Nie wykonano zdalnego testu ani obejścia odrzucenia. Wysłano jedno pytanie z obiema operacjami i przyciskami odpowiedzi. Wymagana jest konkretna odpowiedź właściciela; do jej otrzymania nie tworzyć permitu ani nie uruchamiać run. Bieżące inwentarze i limity pozostają niezmienione.
