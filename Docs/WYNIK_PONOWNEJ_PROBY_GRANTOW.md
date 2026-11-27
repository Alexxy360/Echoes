# Ponowna próba grantów — odpowiedź Apple i format adresów

Po odpowiedzi **„Tak, zatwierdzam jedną ponowną próbę”** wykonano dokładnie1 request `assets/upload` w CloudKit Development dla inwentarza SHA `fac1e30092f49f99f2b951009775123e56177f767bb5c705420b40c95ff6f422`, kod z `ce27fe7`. **Apple odpowiedziało, ale granty nadal nie zostały zaakceptowane.** [Dowody](evidence/asset-grant-authority-development-results.json).

| Pole diagnostyki | Rzeczywista obserwacja |
| --- | --- |
| HTTP | 200 |
| Typ i kodowanie | JSON, gzip |
| Odkodowany rozmiar | 1293 bajty, brak Content-Length |
| Liczba tokenów | 2 |
| Etap odmowy | grants / url_canonical |
| Pozostałe operacje | 0 obrazów,0 zapisów rekordów,0 otwarć zwróconych adresów |

Status HTTP, poprawny JSON i dwa tokeny wykluczają błąd na wcześniejszych etapach tej próby. Parser odrzucił porównanie źródłowego URL z `URL.href`. **Surowego URL nie zapisano; dokładnej różnicy nie znamy. Jawny port443 nie jest jeszcze potwierdzony w odpowiedzi Apple.** Nie odzyskiwano danych z pamięci lub sieci i nie ponawiano requestu. Permit usunięto, attempt i zamknięte metadata zachowano. Mogły powstać czasowe granty Apple, bez obrazu lub rekordu.

## Poprawka zgodnych zapisów HTTPS

Przegląd i3 nowe testy wykazały, że discovery, upload i chroniony download odrzucały nawet równoważne zapisy tego samego originu: jawne443 oraz wielkość liter schematu/hosta. Zasady równoważności opisuje [RFC 9110 §4.2.3](https://www.rfc-editor.org/rfc/rfc9110.html#section-4.2.3). To rzeczywisty lokalny błąd zgodności, a nie dowód dokładnego formatu wcześniejszej odpowiedzi.

Wspólny helper normalizuje wyłącznie authority HTTPS. Zachowuje bajtowo ścieżkę i podpisane query; ich inne przekształcenia nadal powodują odmowę. Trzy callsites nadal wymagają HTTPS, dokładnej odebranej listy hostów, braku credentials/fragmentów i innych portów. Nadal odrzucają backslash, kodowany host, dot-segments, obce domeny i przekierowania. Nie dodano żadnego rzeczywistego hosta do konfiguracji ani wildcardu. Doprecyzowano także odmowę pustego fragmentu `#` w trzech walidatorach; lokalne discovery przed tą zmianą go akceptowało. Odpowiedź JPEG nadal wymaga identity, zgodnego manifestu/SHA i rzeczywistego rozmiaru; obsługa gzip dotyczy wcześniej poprawionego JSON.

Raport discovery zawiera dodatkowo tylko liczniki normalizacji authority/defaultowego443. Błąd może zawierać dwa booleany porównania; bez URL, ścieżki, query, tokenu lub treści. Pozwoli to potwierdzić użycie443 przy przyszłym sukcesie bez zachowywania adresu.

Odbiór lokalny:3/3 nowe testy odtwarzały błąd przed zmianą; po zmianie72/72 testów wybranych modułów, pełne995/995 bez skipów na Node 22.23.5 i995/995na Node 24.22.3,7 kontroli składni oraz zbudowany nieaktywny pakiet Workera. Każdy nowy test obejmuje443, wielkość liter i oba warianty łącznie; upload i download docierają do identycznego dozwolonego celu bez przekazywania bearer. Dodano odmowy niejednoznacznych ścieżek/hostów i pustego fragmentu. Końcowe pełne995/995 na obu Node wykonano ponownie na tych końcowych źródłach; osobny focus72 był przed doprecyzowaniem pustego fragmentu. **Nie wdrażano Workera ani nie zmieniano iOS, SDK, schematu, ról, kluczy, Firebase lub Production.**

## Dalszy ograniczony zakres

Przygotowano [jedną serię do3 prób](ZAKRES_SERII_GRANTOW_DEVELOPMENT.md), trzy odrębne inwentarze i prywatny operator. Jedno wspólne okno30 min,1 request/inwentarz, stop po pierwszym sukcesie, brak ponawiania zużytego ID. Operator ma blokadę jednego procesu, trwałe rezerwacje, wspólny zegar wall/monotonic, sprawdzenie zakończenia poprzedniego procesu i odmowę po sukcesie. Odczyt stanu i próba bez zgody potwierdziły domyślną odmowę przed utworzeniem okna/rezerwacji; składnia poprawna. Nie wykonywano pełnego testu wszystkich awarii tego prywatnego operatora i nie traktujemy go jako odbioru usług.

Seria pozostaje **niezatwierdzona i niewykonana**, bez permitów lub rozpoczętego okna. Poprzednia zgoda1 request jest zużyta. Dopiero zaakceptowane hosty pozwolą przejść do pełnego testu małych JPEG, plików/CAS/chronionego odczytu i sprzątania zgodnie z [planem](PROBA_ASSET_DEVELOPMENT_PLAN.md). Pełna migracja i TestFlight nadal nie są odebrane.
