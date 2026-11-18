# CK-04e.3j.3c.4a — publikacja dokładnego zatwierdzonego wyboru

Przed umożliwieniem ponownej publikacji bez lokalnego upload journala wzmocniono kontrakt istniejącego `publish`. Sam requestID pozwalał serwerowi przyjąć najnowsze zatwierdzenie, nawet gdy autor rozpoczął akcję dla wcześniejszej rewizji moderacji tego samego zdjęcia. Nowy kontrakt zachowuje dokładny wybór autora także podczas oczekiwania na status, checkpoint lub zapis wskazania.

## Żądanie i serwer

POST `/v1/community/avatar/publish` przyjmuje dokładnie pięć pól: requestID, versionID, generation, reviewRevision i consentVersion=1. UUID są kanoniczne, generacja jest dodatnim bezpiecznym licznikiem mniejszym od Number.MAX_SAFE_INTEGER. JSON nadal ma limit512B. Konto pochodzi wyłącznie z sesji; brak pliku JPEG, danych profilu, konta, receipt, URL dostawcy lub uprawnień operatora w body.

Stare requestID-only oraz dodatkowe/brakujące pola są odrzucane, zamiast uzupełniania ich aktualnym stanem serwera. Ten nieaktywny jeszcze protokół wymaga zgodnego klienta i serwera przed przyszłą aktywacją. Nie dodano wariantu automatycznie przyjmującego najnowszą rewizję.

Koordynator sprawdza wersję i generację po checkpoint. Początkowy publish lease nie może zastąpić żądanej rewizji bieżącą. Istniejące kontrole ponawiają zgodność rewizji, descriptor hash i staged tag podczas zapisu, finish oraz synchronicznego finalizera po ostatnim checkpoint. Nowa decyzja moderatora nadal zeruje gotowość i ukrywa zdjęcie. Reapproval tego samego pliku wymaga nowego wyboru autora. Poprzednio odczytanego pliku nie da się w ten sposób cofnąć z urządzenia innej osoby.

Ponowienie dokładnie tego samego żądania pozostaje idempotentne. Nie tworzy nowego uploadu lub plików. Samo consentVersion jest deklaracją aplikacji, nie serwerowym dowodem fizycznego naciśnięcia przycisku.

## Klient natywny

GatewayAvatarPublishIntent ma wyłącznie pięć pól metadanych oraz redagowany opis/reflection. Snapshot lub ta struktura nie stanowią uprawnienia. Klient HTTP wymaga potwierdzenia published z dokładnie tymi samymi requestID/versionID/generation/reviewRevision. Nie przyjmuje sukcesu dla nowszej oceny lub innego zdjęcia.

Istniejący GatewayAvatarOwnerController przechwytuje zatwierdzony, już odczytany snapshot przed pierwszym await. Świeży odczyt statusu nie może podmienić wyboru. Jeśli moderacja zmieniła się przed odczytem lub po nim, klient odmawia albo serwer odrzuca starą intencję. Pozostają bariery natywnego/prywatnego konta, lease, epoki oraz pojedyncza operacja w toku. Po błędzie zachowane ID nie są automatycznie zastępowane lub ponawiane.

To etap przygotowawczy. Istniejący controller nadal wymaga upload journala. Jego rekord nie zapisuje jeszcze osobnej trwałej intencji publikacji z reviewRevision. Następne etapy muszą dodać intencję metadanych bez JPEG, jej odzyskiwanie, chroniony podgląd własnego zatwierdzonego zdjęcia i potwierdzenie autora; nie wolno fabrykować uploadu, checksum lub źródła. Taki podgląd wymaga osobnego dostępu właściciela, bez przyznania dostępu innym osobom lub roli moderatora. Obecnego API i testów nie uznano za zakończenie ponownej publikacji po utracie journala.

## Weryfikacja

[Raport etapu](evidence/avatar-publication-selection-local-tests.json) zapisuje końcowe wyniki i SHA. Osiem nowych testów serwera obejmuje zamknięty input, odmowę requestID-only przez konkretny lokalny Runtime, ponowną ocenę tego samego pliku, obcą wersję/generację/ID, zmianę podczas checkpoint, reapproval po publikacji, finalizer po odrzuceniu oraz idempotencję bez ponownego transferu.

Siedem nowych testów Swift sprawdza dane wejściowe, body i redakcję, dokładne potwierdzenie oraz wymaganie odczytanego zatwierdzenia i zmiany rewizji przed/po świeżym odczycie statusu. Exporter ponownie wytwarza10 odpowiedzi lokalnego Runtime/HTTP/SQLite/Wasm do rzeczywistego klienta Swift i testów sterownika. Apple, tożsamości, bindingi platformy i pliki dostawcy są modelami. Pełna regresja zawiera lokalny workerd/SQL/Wasm; nie jest odbiorem hosted Free, SIWA, ról CloudKit lub kont A/B.

Flagi pozostają wyłączone; nie zmieniono aktywacji, uprawnień, kluczy, sekretów, usług, kosztów, Production lub Firebase. Zwykłe wejście pozostaje Firebase. Wcześniejsze ostrzeżenia ramek SwiftUI oraz wymagane testy urządzenia i dwóch zwykłych kont pozostają otwarte. Etap nie oznacza gotowości TestFlight.
