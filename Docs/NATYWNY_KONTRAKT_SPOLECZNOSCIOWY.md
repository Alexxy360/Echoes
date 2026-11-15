# Natywny kontrakt społecznościowy

CK-04d.1, 15 listopada 2026. Pakiet EchoesCloudKit ma typowany klient HTTP dla wszystkich tras społecznościowych CK-04c. To część natywnej integracji; nie podłączono jeszcze `CommunityClient` do zwykłego AppServices. Firebase pozostaje aktywnym adapterem, a konfiguracja nowej usługi jest nieobecna w aplikacji. Nie wdrożono backendu ani nowych uprawnień/sekretów.

## Implementacja

`GatewayCommunityOperation` określa zamkniętą operację i jej pola: config, visibility, publish/stop, nearby, messages, send, block/blocked, report, profile i profile/save. Nie przyjmuje URL, właściciela zapisu, dowolnych nazw rekordów, pól CloudKit ani dowolnej ścieżki HTTP. Żądania mają JSON, Bearer access token i no-store. UUID są małymi literami; współrzędne, generacje, Unicode, limity UTF-16, revision, cursor i knownIDs są sprawdzane przed połączeniem. Codable pozwala zachować konkretną operację w przyszłym dzienniku, ale samo w sobie nie jest trwałym ani chronionym zapisem.

`GatewayCommunityHTTPClient` mapuje odpowiedzi do istniejących `NearbyProfile`, `ChatMessage`, `MessagePage` oraz osobnego własnego profilu z revision. Sprawdza wersję, inwentarz pól, czas serwera (dopuszczalne odchylenie zegara do 5 min), identyfikatory, limity/duplikaty, kolejność strony, kontrolki i czasy. removedIDs muszą pochodzić z przesłanych knownIDs. Nearby sprawdza także rzeczywistą odległość do przybliżonej pozycji i zgodność serwerowego distanceMeters. Odpowiedź potwierdzająca send musi zawierać tę samą nazwę/treść i zgodny ID; zmiana profilu musi potwierdzać żądaną nazwę. To walidacja protokołu, nie zastępstwo kontroli właściciela na serwerze i natywnego wiązania konta przez przyszły adapter.

`send` na serwerze zwraca teraz także pełne `message`: ID, autora, nazwę, treść i **pierwotne serwerowe** timestamp/expiresAt. Klient nie tworzy ich z lokalnego zegara. Potwierdzenie ponowionej operacji może dotyczyć już wygasłej wiadomości: pozwala rozstrzygnąć stary zapis bez utworzenia nowej wiadomości. Taki obiekt nie przechodzi filtra widocznej osi czasu. Dla zwykłej strony czatu odpowiedź z wygasłą wiadomością jest odrzucana.

`NativeGatewayTransport.community()` używa tego samego efemerycznego URLSession bez cookies/cache/credential storage i z odmową przekierowań. Podnosi limit odpowiedzi tylko dla tego transportu do 256 KiB; domyślne logowanie/usuwanie zachowuje 32 KiB. Klient społecznościowy ma dodatkowy limit odebranych danych i 48 KiB żądania. Strona 50 wiadomości po 500 jednostek UTF-16 może przekroczyć 32 KiB, co potwierdza test z emoji. Limit strumienia działa również bez Content-Length.

`ActivatedGatewayCommunityAPI` porównuje origin z jawną konfiguracją bundled Development i sprawdza okno aktywacji przed i po await. Anulowana operacja HTTP nie oddaje spóźnionej odpowiedzi. Nie ma automatycznych ponowień, zmiany origin z odpowiedzi, przyjmowania sekretu z linku ani domyślnego użycia diagnostycznego Workera. Błędy mają skończone lokalne opisy, bez upstream reason/cause i bez automatycznego retry; Retry-After jest tylko ograniczoną informacją.

## Odbiór lokalny

`gateway/scripts/export-community-native-fixture.mjs` uruchamia rzeczywisty lokalny HTTP handler/koordynator/rejestr SQLite i podpisany model CloudKit. Eksportuje 13 par request/response, obejmujących wszystkie operacje oraz pusty i zapisany profil. Nie używa prawdziwego Apple/CloudKit/Cloudflare i nie eksportuje tokenów/kluczy. Swift konsumuje ten sam JSON i porównuje swoje wysyłane pola z wejściem serwera. Resource należy wyłącznie do targetu testowego; nie jest treścią ani konfiguracją aplikacji.

171/171 testów EchoesCloudKit (9 nowych) obejmuje zgodność między implementacjami, duże Unicode strony, błędne typy/czasy/pola/duplikaty/kolejność, obcy removedID, zły cursor/zasięg, niewłaściwy ack, pierwotny czas wygasłego ack, input przed dispatch, bezpieczne błędy, strumień i późne odpowiedzi po anulowaniu/wygaśnięciu aktywacji. Gateway 256/256 na Node 22.23.5 i 24.22.1, z nowymi asercjami pełnego oryginalnego ack po utraconej odpowiedzi.

Wyniki Debug/Release, kontrola pakietu i SHA źródeł/logów: [native-community-contract-tests.json](evidence/native-community-contract-tests.json). Pierwszy Debug zatrzymał się na niekompletnym cache przypiętych Git trees; drugi cache zweryfikowano dla wszystkich rewizji i użyto bez zmiany Package.resolved lub bibliotek. Nie zaliczono pierwszej próby jako poprawnej kompilacji. Brak zmian UI, dlatego nie powtarzano testów wizualnych; realnych providerów, Keychain nowego dziennika, A/B ani instalacji telefonu nie wykonywano.

## Dalsza integracja

CK-04d.2 musi połączyć API z `CommunityClient`, aktualnym `GatewaySignInHost` oraz jego access tokenem i natywną tożsamością. Każda spóźniona odpowiedź musi zostać odrzucona po zmianie konta, tła, rewizji lub usuwaniu. Wymagany jest trwały, ograniczony dziennik requestID/oryginalnego payloadu w chronionym storage przypisanym do origin, Apple/iCloud binding i UUID konta; nie wolno odtworzyć starego zamiaru jako operacji innego konta. Nie zamieniać nieznanego wyniku w sukces i nie ponawiać pod nowym ID.

Następnie integracja mapy/czatu, recovery szkicu, generacji widoczności i blokad, odpowiedni host/UI oraz owner-scoped czyszczenie dziennika podczas usuwania. `deleteOwnData` nie może pozorować usunięcia przez zwykły endpoint społecznościowy: wymagany jest istniejący przepływ świeżego Apple proof. Profile innych osób/zdjęcia, retencja, operator/kontakt, rzeczywisty schemat/role/SIWA/Workers Free i zwykłe konta A/B pozostają w pełnym planie. Nie odłączono Firebase ani nie publikowano TestFlight/Production.
