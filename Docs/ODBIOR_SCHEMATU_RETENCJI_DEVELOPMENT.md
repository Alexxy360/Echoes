# Odbiór schematu retencji w Development — przygotowanie CK-05a.4

Status: plan gotowy do porównania z rzeczywistym eksportem; **schemat nie został odczytany ani zmieniony**. `cktool export-schema` odmówił lokalnie z powodu braku management tokenu. Otwarta konsola Apple wymaga ponownego logowania właściciela. Nie utworzono tokenu ani nowego klucza.

Ten dokument nie jest plikiem do importu. Nie wolno zastępować nim pełnego schematu kontenera. Najpierw potrzebny jest bieżący eksport, ponieważ zawiera również istniejące typy diagnostyczne oraz prywatne i ich uprawnienia.

## Dokładna różnica wynikająca z CK-05a.1–3

| Typ publiczny | Pole potrzebne do blokady retencji | Typ pola |
| --- | --- | --- |
| `EchoesPresenceV1` | `retentionKey` | `STRING` |
| `EchoesLocalMessageV1` | `retentionKey` | `STRING` |
| `EchoesReportV1` | `retentionKey` | `STRING` |

Wspólne pola blokady to `schemaVersion: INT64`, `ownerKey: STRING`, `erased: INT64`. Mechanizm usuwania konta używa osobnego `deletionKey: STRING`. `retentionKey` nie jest uprawnieniem ani terminem — jest skrótem konkretnej intencji z rejestru serwera. Samo dodanie tych trzech pól nie przygotowuje całego schematu społecznościowego.

Retencja wybiera rekordy z własnego SQLite i odczytuje dokładne ID; nie potrzebuje nowego indeksu wyszukiwania CloudKit po `retentionKey`. Zapytania mapy/czatu wymagają niezależnego odbioru indeksów pól `location`, `erased`, `expiresAt`, `active`, `createdAt`, `updatedAt` oraz sortowania po systemowym `recordName`, zgodnie z konkretnym zapytaniem klienta. Nie przyznaje to dostępu do tych danych klientowi iOS.

## Kolejność wykonania

1. **Odczyt bez modyfikacji:** sprawdzić zespół `22YC9RAP4P`, kontener `iCloud.mpvEcho.Echo`, środowisko Development i publiczną bazę. Wyeksportować schemat; zachować lokalny plik i SHA. Nie otwierać treści rekordów użytkownika ani prywatnego profilu w celu poznania schematu.
2. **Porównanie całości:** ustalić, które typy już istnieją. Obecny kod zna `EchoesPublicProfileV1`, `EchoesPresenceV1`, `EchoesLocalMessageV1`, `EchoesBlockV1`, `EchoesReportV1`, `EchoesAvatarV1`, `EchoesAvatarProfileV1` i `EchoesRegistryCheckpointV1`. Brak typu oznacza konieczność przygotowania jego pełnego kontraktu, zamiast wysłania niepełnej trzykolumnowej poprawki. Sprawdzić także typy, pola i indeksy istniejące poza tą listą; zachować je.
3. **Uprawnienia:** porównać rzeczywiste role z architekturą gateway. Chronione typy nie mogą przyznawać zwykłym klientom praw przez `_world`, `_icloud` ani `_creator`; szczególnie poufne są zgłoszenia i blokady. Osobna tożsamość serwerowa ma otrzymać wyłącznie potrzebne prawa. Klucz operatora nie jest dowodem działania tej osobnej tożsamości. Nie zmieniać ról w ciemno, nie nadawać praw całemu kontenerowi i nie zmieniać praw istniejących typów prywatnych.
4. **Przygotowanie zmiany:** z eksportu stworzyć osobny plik z dokładną różnicą i opisem wszystkich nowych typów/pól/indeksów/ról. Wskazać uprawnienia, które zmiana odbiera lub nadaje. Dopiero taki wynik pozwala uzyskać konkretną zgodę na zapis w Apple. Przed importem ponownie porównać eksport, by nie nadpisać zmian z innej sesji.
5. **Walidacja i zapis Development:** walidacja Apple oraz ewentualny import dotyczą wyłącznie uzgodnionego kontenera i Development. Nie wykonywać `reset-schema`, usuwania typów, promocji do Production ani automatycznego tworzenia brakujących struktur przez zwykły ruch aplikacji.
6. **Ograniczony test protokołu:** przygotować lokalny harness z losowymi syntetycznymi identyfikatorami, dokładnym inwentarzem i zakresem oczyszczania przed wystąpieniem o zgodę. Test ma sprawdzić create/lookup/CAS replace i pełną odpowiedź po usunięciu pól, w tym zachowanie null dla usuniętego pola. Nie może korzystać ze stałego checkpointu prawdziwego gateway ani zakładać jego własności. Usuwa wyłącznie swoje znane rekordy po tagu; błąd oczyszczania pozostawia zapis dokładnych ID do kontrolowanego recovery, bez query/delete całego typu. Definicje typów pozostają.
7. **Rzeczywiste ACL i platforma:** osobno sprawdzić zwykłe konto A i B, brak odczytu/zapisu bez gateway, działanie tożsamości serwera, jej odebranie oraz alarm i zużycie Free. Przy jednym koncie operatora ten punkt pozostaje niezaliczony. Poprawny wynik syntetycznego testu protokołu nie zastępuje tego odbioru.

## Kryteria wyniku

Każdy etap zachowuje osobno: SHA eksportu wejściowego, dokładną różnicę, przyznaną zgodę/okno, wynik Apple, inwentarz własnych rekordów oraz wynik ich oczyszczania. Raport rozdziela „pole przyjęte przez schemat”, „usunięto wartości treści”, „zwykły klient nie ma dostępu” i „działa hostowany alarm”. Nie wolno łączyć tych stwierdzeń w jedno zaliczenie na podstawie konta operatora.

Lokalny odbiór [CK-05a.3](ALARM_I_BUDZETY_RETENCJI.md) pozostaje ważny dla kodu i syntetycznej kompozycji. Flagi usług pozostają `0`, bez publikacji Production, nowego przekazania sekretów, opłat i operacji na dawnych danych Firebase.
