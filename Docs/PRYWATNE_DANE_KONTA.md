# Prywatne dane konta — CK-03b

Stan z 14 listopada 2026: lokalna implementacja i testy modelu. Zwykły interfejs nadal używa Firebase; nie zmieniano schematu ani danych CloudKit. Ten etap przygotowuje bezpieczne czyszczenie prywatnych danych przed natywnym biletem usuwania konta.

## Przestrzeń konta

`PrivateAccountScope` łączy kontener, środowisko, skrót natywnego userRecordName i UUID konta zwrócony przez zweryfikowaną bramkę. Wyznacza osobną strefę prywatną `echoes.private.v1.<SHA256>`. Nie używa IDFV i nie przyjmuje UUID wybranego w UI jako dowodu własności. Skrót identyfikuje przestrzeń; nie jest sekretem ani autoryzacją.

W strefie znajdują się `EchoesPrivateProfileV1/profile.v1` i `EchoesPrivateScopeV1/scope-guard.v1`. Guard ma schemaVersion=1, scopeDigest, deleted (0/1), losowy mutation UUID oraz deletionID po rozpoczęciu usuwania. Zachowujemy change tag i nieznane pola. Profil nadal zawiera tylko pseudonim. Store wymaga jawnego dostawcy aktualnej przestrzeni, a cache jest związany zarówno z revision iCloud, jak i kontem Echoes.

`NativePrivateZoneTransport` korzysta wyłącznie z privateCloudDatabase. Sprawdza bieżące accountStatus/userRecordID przed i po operacjach, zgodność konfiguracji i identyfikatorów oraz wyniki każdego rekordu. Nie przechodzi na publiczną bazę przy błędzie. Sama konfiguracja Swift nie potwierdza entitlements: host musi przejść dotychczasową kontrolę podpisywania.

Identyczne nazwy rekordów w prywatnych bazach różnych użytkowników nie oznaczają same w sobie współdzielenia danych. Osobne przestrzenie i kontrole właściciela ograniczają pomylenie kontekstu konta w aplikacji. Rzeczywista zmiana iCloud i próba dwóch kont pozostają wymagane.

## Zapis i bariera usuwania

Host dostarcza obowiązkowy callback `authorizePrivateWrite`. Sprawdza natywny credentialState, powiązanie Keychain/iCloud i świeże `/v1/auth/session` dla właściwego konta. Baza wywołuje go również bezpośrednio przed mutacją. Nie wystarcza wcześniejsze otwarcie ekranu albo nieprzeterminowany token bez kontroli serwera. Kontrole klienta nie stanowią ACL przeciw zmodyfikowanemu właścicielskiemu klientowi; prywatna baza pozostaje pod kontrolą użytkownika iCloud.

Profil i zmieniony guard zapisują się atomowo w jednej strefie, z ifServerRecordUnchanged. Wymagana jest capability atomic, bez słabszego fallback. Rozpoczęcie usuwania zmienia guard w deleted=1. Starszy zapis ma nieaktualny change tag, więc w modelu nie odtwarza profilu; nowszy zapis odrzuca stan usuwania. Brak guarda przy istniejącym profilu, obcy identyfikator i uszkodzony/nowszy schemat nie są traktowane jako pusta baza.

`deleteProfile` usuwa tylko profil i pozostawia aktywną przestrzeń. Nie oznacza usunięcia konta. `eraseAccountContentStep` wymaga osobnej autoryzacji zaakceptowanego przez serwer zadania dla dokładnie tego konta. Zwykły access token lub UUID klienta nie zastępują biletu. To połączenie nie jest jeszcze zaimplementowane.

## Czyszczenie i wznowienie

Jeden krok przegląda najwyżej 100 zmian/rekordów w przypisanej strefie, bez pobierania pól użytkownika. Usuwa zawartość wszystkich typów, także przyszłych, i aktualizuje guard w tej samej atomowej operacji. Nie wylicza całej prywatnej bazy ani innych stref. Kursor zawiera zabezpieczony serializacją SDK changeToken oraz powiązanie z digest i deletionID; opis/debug/reflection nie pokazują tokenu. Przechowywać go w prywatnym magazynie biletu, nigdy w logach.

`contentDeleted=true` pojawia się dopiero na stronie bez zawartości i bez moreComing. Błąd strony, konflikt, zmiana konta lub utrata odpowiedzi nie są sukcesem. Po niepewnym wyniku caller może ponownie przeskanować własną strefę; nie otrzymuje fałszywego potwierdzenia. Zapis kursora i późniejszy HTTP private-cleanup są obowiązkiem przyszłego klienta biletu.

Pozostaje minimalny guard blokujący stare zapisy. Nie deklarujemy pustej całej bazy ani kompletnego usunięcia wszystkich prywatnych metadanych. Polityka retencji i końcowego usunięcia guarda nadal wymaga wdrożenia przed wydaniem. Usunięcie rekordów z CKAsset wymaga osobnego potwierdzenia dostawcy; lokalne testy nie mierzą fizycznego usunięcia plików.

Starszy, niewpięty do zwykłego UI komponent używał domyślnego `private-profile.v1` bez UUID konta Echoes. Jego wykrycie jest tylko odczytem metadanych i blokuje zakończenie czyszczenia. Nie zgadujemy właściciela ani nie usuwamy tego rekordu automatycznie. Migracja lub jawna decyzja właściciela pozostaje do przygotowania, jeśli taki rekord rzeczywiście istnieje.

## Weryfikacja i dalszy odbiór

90/90 testów pakietu Swift na macOS: 18 nowych (14 modelu stref, 2 store, 2 hosta). Obejmują izolację kont, świeżą autoryzację zapisu, atomowe współbieżne operacje, 206 rekordów w kilku stronach, zachowanie innej strefy, niepewną odpowiedź, restart/kursor, legacy i błędy. Model transportu symuluje change tag przez numer wersji; nie jest testem zachowania CloudKit. Debug i Release kompilowane z zatwierdzonym w Git project.pbxproj, bez podpisywania. [Dowody](evidence/private-account-data-local-tests.json).

Do odbioru: SDK atomic/change token/konflikt i CKAsset na danych syntetycznych Development, rzeczywista zmiana iCloud i dwa zwykłe konta, bilet w Keychain/HTTP/status/private ACK, retencja guarda, obsługa legacy i połączenie z interfejsem. Usługi pozostają nieaktywne; brak nowych uprawnień, kluczy, opłat i zmian Production.

## Dokumentacja Apple użyta przy implementacji

- [Prywatna baza](https://developer.apple.com/documentation/cloudkit/ckcontainer/privateclouddatabase) i [zakres identyfikatorów rekordów](https://developer.apple.com/documentation/cloudkit/ckrecord/id).
- [Kontrola konta](https://developer.apple.com/documentation/cloudkit/ckcontainer/accountstatus(completionhandler:)) oraz [powiadomienie zmiany konta](https://developer.apple.com/documentation/foundation/nsnotification/name-swift.struct/ckaccountchanged).
- [Atomowość operacji](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/isatomic), [capability strefy](https://developer.apple.com/documentation/cloudkit/ckrecordzone/capabilities-swift.struct/atomic) i [polityka konfliktów](https://developer.apple.com/documentation/cloudkit/ckmodifyrecordsoperation/recordsavepolicy/ifserverrecordunchanged).
- [Stronicowane zmiany strefy i token SDK](https://developer.apple.com/documentation/cloudkit/ckdatabase/recordzonechanges(inzonewith:since:desiredkeys:resultslimit:)).
