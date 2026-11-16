# Ograniczona diagnostyka prywatnego SDK CloudKit

Etap CK-04e.2. Kod testu jest wyłącznie Debug. Bez ważnego zasobu `EchoesPrivateProfileProbe.json` SDK nie jest konstruowane, także przy fladze autorun. Zasób jest ignorowany przez Git; standardowe pakiety go nie zawierają.

## Przygotowany zakres na telefonie

Istniejący iPhone 15 Pro, App ID `mpvEcho.Echo`, zespół `22YC9RAP4P`, kontener `iCloud.mpvEcho.Echo`, wyłącznie prywatna baza Development. Korzystamy z istniejącego podpisu i profilu. Instalacja zastępuje wersję deweloperską, bez odinstalowywania i kasowania jej danych. Przed uruchomieniem trzeba ponownie sprawdzić podpis, środowisko i dokładny zasób w zbudowanym pakiecie.

Przygotowano najwyżej trzy próby w jednym wspólnym oknie do 30 minut. Każda ma inny runID i dwa z góry wylosowane identyfikatory syntetycznych kont Echoes. Okno nie przedłuża się automatycznie. Właściwa aktywacja powstanie dopiero po konkretnej zgodzie właściciela; dotychczasowe zgody na pojedynczy rekord i wygasłe okna nie obejmują nowych typów ani tej sekwencji.

## Operacje i granice

1. Trwały, wyłączny marker runID w chronionym katalogu aplikacji poprzedza konstrukcję natywnego źródła. Próba nie powtarza się po ponownym uruchomieniu procesu.
2. Sprawdzenie dostępności iCloud, odczyt identyfikatora konta przez SDK, wyprowadzenie dwóch własnych nazw stref z bieżącej tożsamości. Identyfikator iCloud nie trafia do raportu.
3. Odczyt metadanych dokładnie tych dwóch stref; kolizja z istniejącą strefą zatrzymuje zapis. Nie wyliczamy innych stref.
4. Utworzenie syntetycznego pseudonimu w pierwszej strefie, odtworzenie przez nowy Store, aktualizacja i celowy zapis starego CKRecord. Zaliczenie wymaga rzeczywistego błędu serwera `serverRecordChanged` i zachowania nowej wartości.
5. Osobny syntetyczny pseudonim w drugiej strefie; sprawdzenie rozdzielenia przestrzeni dwóch UUID aplikacji na tym samym koncie iCloud. **To nie jest test A/B dwóch kont Apple.**
6. Stronicowany cleaner pierwszej strefy i bariera usuwania; kolejny zapis musi zostać odrzucony. Cleaner sprawdza także samo istnienie starego `private-profile.v1` w domyślnej strefie, bez pobierania jego pól. Jeżeli istnieje, abortuje zamiast go usuwać.
7. Usunięcie wyłącznie dokładnych stref wcześniej potwierdzonych jako nieistniejące oraz sprawdzenie ich nieobecności. Usunięcie strefy jest trwałe. Błąd, wygaśnięcie lub zmiana konta blokuje kolejne operacje; niepotwierdzone sprzątanie pozostaje jawnie do odzyskania, bez samowolnego przedłużenia dostępu.

Każdy nowy dispatch jest ograniczony czasem, przestrzenią i niezmienioną tożsamością. Już wysłana operacja SDK może zakończyć się po terminie; nie jest obiecywane jej cofnięcie. Maksymalnie cztery kroki cleanera. Bez GPS, Muzyki, treści istniejącego profilu, Firebase, Cloudflare, kluczy serwerowych i zmian Production. Diagnostyczny callback autoryzacji dopuszcza tylko powyższy plan; nie sprawdza prawdziwej sesji gateway ani biletu usuwania.

## Typy i pozostałości schematu Development

SDK może utworzyć typy w Development:

| Typ | Pola |
| --- | --- |
| `EchoesPrivateProfileV1` | `schemaVersion` Int64, `displayName` String |
| `EchoesPrivateScopeV1` | `schemaVersion` Int64, `scopeDigest` String, `deleted` Int64, `mutation` String, opcjonalny `deletionID` String |

Rekordy mają stałe nazwy `profile.v1` i `scope-guard.v1` we własnych losowych strefach. Definicje typów pozostają w schemacie Development po usunięciu danych. Nie publikujemy schematu Production ani nie zmieniamy ról innych typów. [Apple: usuwanie strefy](https://developer.apple.com/documentation/cloudkit/ckdatabase/deleterecordzone(withid:)).

## Przygotowane próby

Poniższe UUID nie są tokenami ani rzeczywistymi kontami. Stanowią ograniczony zakres zgody; nie aktywują testu bez dat i podpisanego pakietu.

- Próba 1: runID `b658e6a1-959d-4661-8ef4-bd85358641ab`; konta `bc120294-655a-4148-88cc-c0f304739070` i `b6f773c8-b5ba-424d-9be0-6bfccc3ec2a8`.
- Próba 2: runID `401a1e6d-1342-4403-80d7-ce643358dec6`; konta `20094ab8-e878-4d66-abce-61feeeb69a53` i `54899413-d60b-423c-b6e2-1f69a84fe330`.
- Próba 3: runID `04b8df33-c911-4c24-a00c-991779f8d26a`; konta `a81eb335-5699-419c-b207-d67f60a8a55b` i `cb5ba716-fd77-4f70-b015-41985aebb220`.

## Dowody i odbiór

Przygotowanie lokalne: 212/212 testów Swift (8 nowych: konfiguracja i rzeczywiste plikowe markery), 2/2 XCTest UI na zatwierdzonym iPhone 17 Pro Simulator/iOS 26.1. Podpisana nieaktywna wersja Debug dla iPhone’a zbudowana; podpis i istniejący profil przeszły preflight Development. Pierwsza kompilacja telefonu odpadła, ponieważ globalne wymuszenie profilu objęło też resource bundles SPM; końcowa używa istniejącego automatycznego podpisywania bez aktualizacji profili. Nie instalowano jej i nie wykonano operacji CloudKit.

Raport z próby zawiera tylko runID, czas, etapy, flagi, liczbę posprzątanych stref i kody błędów SDK. Chroniony plik `Documents/PrivateProfileSDKProbe/result-<runID>.json` oraz prefiks stdout `ECHOES_PRIVATE_PROFILE_SDK_RESULT` służą do odczytu. Brak surowego identyfikatora iCloud i treści profilu. Marker próby pozostaje lokalnie; nie zapisuje danych w treści pliku.

Rzeczywisty wynik CK-04e.2b: **pierwsza próba przeszła na iPhonie 15 Pro/iOS26.7.1**, po konkretnej zgodzie właściciela. Wspólne okno 16 listopada 2026: 11:53:20–12:23:20 UTC; test rozpoczął się o 11:56:30 UTC. Użyto tylko pierwszego runID. Odtworzenie przez nowy Store, rzeczywisty change tag i błąd serwera `serverRecordChanged` (14), rozdział dwóch przestrzeni na tym samym iCloud oraz cleaner/bariera przeszły. Obie własne strefy usunięto i SDK ponownie potwierdziło ich nieobecność. Kolejnych prób nie uruchamiano. Typy zostały zaakceptowane przez SDK; konsoli schematu/ról osobno nie sprawdzano.

Chroniony raport pobrano z dokładnego pliku aplikacji i porównano z konsolą. Po zakończeniu zainstalowano podpisany pakiet bez zasobu aktywacji, bez ponownego uruchamiania SDK. Ponowna kopia chronionego raportu po wymianie aplikacji zwróciła zdalne `openat EPERM`; nie uznajemy więc zachowania pliku/markera po tej wymianie za zweryfikowane. Oryginalny raport był już zabezpieczony. [Raport SDK](evidence/private-profile-sdk-device-result.json), [podpisy, SHA i granice dowodu](evidence/private-profile-sdk-device-verification.json).

To nie jest test dwóch kont Apple, procesu po restarcie, prawdziwej autoryzacji gateway lub biletu/ACK usuwania. Zdjęcia/CKAsset, zmiana iCloud, SIWA/Workers Free, role i drugie zwykłe konto nadal wymagają osobnego odbioru według [planu migracji](PLAN_MIGRACJI_CLOUDKIT.md).
