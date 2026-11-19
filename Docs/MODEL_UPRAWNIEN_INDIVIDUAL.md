# Konto Individual i tożsamość serwera — decyzja do zatwierdzenia

19 listopada 2026. **Analiza przygotowana; model z kontem właściciela jako administratorem nie jest jeszcze zatwierdzony.** Nie nadano nowych ról, nie utworzono klucza ani nie aktywowano gateway. Właściciel potwierdził, że wydaje jako osoba fizyczna i nie dysponuje organizacją.

## Ustalone fakty

W zalogowanej stronie Membership details potwierdzono zespół `22YC9RAP4P`, Apple Developer Program, `Enrolled as Individual`. Panel Container Permissions dla `iCloud.mpvEcho.Echo` pokazał jednego członka zespołu — właściciela. Odczyt nie zmienił żadnego checkboxa. Nie zapisujemy tu adresu e-mail ani innych danych członkostwa.

Apple wskazuje, że dodatkowi użytkownicy App Store Connect przy członkostwie Individual nie stają się członkami zespołu Apple Developer. Dostęp CloudKit Console jest powiązany z uprawnieniami Certificates, Identifiers & Profiles. [Role Apple](https://developer.apple.com/help/account/access/roles/).

Klucz CloudKit server-to-server uzyskuje dostęp do publicznej bazy jako deweloper, który go utworzył; dziedziczy jego uprawnienia. Oddzielny plik klucza nie tworzy drugiej tożsamości iCloud. [Web Services Apple](https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/SettingUpWebServices.html), [przykład Apple](https://developer.apple.com/go/?id=cloudkit-catalog). Potwierdza to wcześniejszy rzeczywisty test projektu: bez roli zapis S2S był odrzucony, a po przypisaniu roli do konta przeszedł.

Wniosek z tych zasad i obecnej konfiguracji: zwykłe utworzenie drugiego Apple ID i zaproszenie go do App Store Connect nie zapewni planowanego drugiego twórcy klucza w tym zespole. Nie mamy potwierdzonego sposobu uzyskania takiej odrębnej tożsamości na obecnym członkostwie. Nie należy deklarować, że wystarczy kliknąć „dodaj konto serwera”.

Organization ma osobne wymagania, w tym kwalifikację podmiotu przez Apple; nie zakładamy ich spełnienia ani zmiany członkostwa. [Wymagania Apple](https://developer.apple.com/help/account/membership/program-enrollment/).

## Proponowany wariant dla obecnego konta

Zachowujemy CloudKit i projekt bramki Workers Free. Konto Apple Developer właściciela pełni również rolę administratora danych społecznościowych. Dla bramki przygotowujemy oddzielne klucze i sekrety, ale dokumentujemy, że ich tożsamość iCloud pozostaje tożsamością właściciela.

Nowe typy mają już zadeklarowane READ/CREATE/WRITE wyłącznie dla `EchoesCommunityService`, bez grantów `_world`, `_icloud` i `_creator`. Po osobnym przygotowaniu i zatwierdzeniu nadania roli konto właściciela mogłoby wykonywać operacje na tych typach. **Ta analiza sama nie upoważnia do takiego przypisania.** Dotychczasowy klucz diagnostyczny również dziedziczyłby nowe prawa tego samego konta; przed jakimkolwiek nadaniem trzeba przygotować jego kontrolowane unieważnienie/rozliczenie pozostałych kopii oraz nowy klucz Development. Nie wolno rozszerzyć jego praw w tle.

| Element | Skutek proponowanego modelu |
| --- | --- |
| Zwykłe konto użytkownika | Brak deklarowanych praw do nowych typów przez standardowe role; odczyt/zapis przez gateway i jego politykę. Wymaga rzeczywistego testu A/B. |
| Konto właściciela z rolą serwera | Ma uprawnienia administracyjne do tych typów również z SDK na urządzeniu zalogowanym na to samo iCloud. Zmodyfikowany klient tego konta może ominąć ograniczenie bramki do lokalnego obszaru i filtrów. |
| Klucz serwera | Pozostaje poza aplikacją/Git. S2S dotyczy publicznej bazy konkretnego kontenera/środowiska; nie daje tym kluczem dostępu do prywatnych profili. Sam oddzielny klucz nie odbiera praw kontu właściciela. |
| Testy użytkowników | Wymagają dwóch nieuprzywilejowanych kont, różnych od konta właściciela. Dotychczasowy iPhone właściciela nie zastąpi tych kont. Nie wylogowujemy go automatycznie. |
| Koszt i publikacja | Propozycja nie wymaga nowej organizacji ani aktywacji płatnej usługi. Limity Free i rzeczywiste zużycie nadal wymagają odbioru; nie stanowi obietnicy bezpłatności przy dowolnej skali. Brak zmian Production. |
| Wcześniejszy wymóg osobnej tożsamości | Nie jest spełniony. Przyjęcie tego modelu wymaga jawnej decyzji właściciela o zastąpieniu go udokumentowanym kontem administracyjnym i osobnymi kluczami. Nie oznaczamy go po prostu jako zaliczony. |

## Zakres decyzji i kolejność dalszej pracy

Decyzja dotyczy modelu uprawnień dla obecnego członkostwa Individual. Jej przyjęcie nie jest zgodą na przypisanie roli, rejestrację/przekazanie klucza, unieważnienie starego klucza, zapis/usuwanie rekordów ani uruchomienie hostowanej usługi. Te operacje wymagają przygotowanego, konkretnego zakresu.

Po przyjęciu modelu: przygotować inwentarz i ograniczony test protokołu Development; opisać skutki wycofania starego klucza diagnostycznego i nowego klucza, dokładne nadanie roli oraz okno testu/oczyszczania. Potem konkretne zatwierdzenie operacji, testy kont i odbierania praw. Zwykłe konta A/B, SIWA, realne zapytania/assety, alarm/Free i reszta planu nadal pozostają wymagane przed przygotowaniem wydania.

Jeżeli właściciel zachowa wymaganie całkowicie osobnej tożsamości iCloud serwera, nie aktywujemy opisanej alternatywy. Potrzebne jest potwierdzenie przez Apple dopuszczalnej ścieżki na takim członkostwie albo osobna decyzja architektoniczna. Nie kupujemy innego członkostwa i nie zamieniamy backendu samodzielnie.
