# R-03b — ASSETID potwierdzone w rzeczywistej projekcji Apple

Właściciel odpowiedział „zgadzam sie” na serię SHA86327f1d… do dwóch prób w jednym wspólnym oknie 30 minut. Pierwszy inwentarz SHA21f2bb4e… uruchomiono kodem `78d63e6`.

Oba uploady przyjęte; create avatara nie zwrócił już HTTP 400. Odczyt rekordu dał HTTP 200/JSON/gzip/3938 B, lecz produkcyjny walidator zgłosił PUBLIC_RESPONSE. Ten sam walidator przerwał sprzątanie. Pełny proces zakończony/code3, pending IO false, permit usunięty; drugiego inwentarza nie uruchomiono. Pierwotny wynik nadal opisuje niepełne cleanup i nie został nadpisany.

## Domknięcie zatwierdzonego sprzątania

Przygotowano i sprawdzono narzędzie wyłącznie do cleanup tych samych dwóch rekordów. Na podstawie prywatnego SQLite i intencji odtworzono właściciela, metadane, manifesty, checksum commitments i konkretny checkpoint. Przy usuwaniu pomija ono wyłącznie ograniczoną opcjonalną etykietę typu; nadal musi przejść pełna produkcyjna walidacja własności, pól, obu rozmiarów/SHA i podpisów plików. Nie służy zwykłemu odczytowi/publikacji i jest domyślnie wyłączone.

W ramach istniejącej zgody na warunkowe usunięcie dokładnie tych rekordów, bez przedłużenia oryginalnego okna lub resetu attempt, wykonano **3 dodatkowe API**: dokładny lookup, warunkowe delete obu rekordów ze świeżymi tagami, końcowy lookup. Oba delete przyjęte, oba ID nieobecne, brak pending IO. **Pierwszy inwentarz łącznie 29/64 API**, 2 uploady/2753 B, 0 pobrań; cleanup nie tworzył rekordów ani nie wysyłał obrazów. Fizyczne usunięcie danych Apple/CDN pozostaje niepotwierdzone.

Ta odpowiedź Apple ujawniła **ASSETID** dla obu pól. Samo usunięcie etykiety w narzędziu cleanup pozwoliło przejść istniejącej walidacji metadanych/checksumów. Normalny walidator dopuszcza teraz zamkniętą listę: brak opcjonalnej etykiety, ASSET i zaobserwowane ASSETID; inne etykiety nadal odrzuca. Nowy test odtworzył PUBLIC_RESPONSE przed zmianą, po poprawce przechodzi. Nie wyciągamy z tego wstecznego wniosku o dokładnej treści wcześniejszego HTTP 400, której nie zachowano.

## Dowody i dalsza próba

[Dowody](evidence/avatar-assetid-development-progress.json) zawierają pierwotny wynik, osobny cleanup i ich hashe; bez rawURL, receiptów, body, podpisów i danych użytkowników. **1021/1021 testów** na Node22.23.5 i24.22.3, 0 skipów; 7 nowych testów (5 cleanup i2 wire), 4 syntax, nieaktywny bundle zbudowany/niewdrożony. Sprzątanie sprawdzono lokalnie na obu Node: zły checksum lub obcy checkpoint blokuje delete, konflikt nie powoduje force/retry, domyślnie brak sieci.

Operator rozpoznaje osobny, przypięty hashami dowód rzeczywiście ukończonego cleanup i dolicza 3 API. Sprawdza ten sam inwentarz/okno, brak uploadów/create/pending IO, granice czasu i budżetu; nie zamienia historycznej porażki w sukces protokołu. Siedem lokalnych kontroli tego warunku, także hash/niepewność/termin/budżet; pełnej maszyny awarii operatora nadal nie zaliczono. Warunek aktualnego potwierdzonego cleanup jest spełniony; druga, już zatwierdzona próba pozostaje możliwa wyłącznie w niezmienionym wspólnym oknie i limicie. Jeżeli upłynie, nie odnawiamy go.

Pełne przypięcie/settle, odmowa starego CAS, pobranie dwóch wariantów i pozostały R-03 nie są jeszcze odebrane. Konto/tożsamość lokalnego testu pozostaje syntetyczna; nie zastępuje SIWA, 3 km, pełnego czytnika lub A/B.
