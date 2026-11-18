# CK-04e.3j.3c.4c.2 — natywne API podglądu zatwierdzonego zdjęcia autora

Pakiet EchoesCloudKit otrzymał osobny klient i transport dla [chronionego endpointu autora](PODGLAD_ZATWIERDZONEGO_ZDJECIA_AUTORA.md). Pobiera zatwierdzony pełny JPEG także przed publikacją, dekoduje go przez rzeczywiste ImageIO i wiąże wynik z dokładnym wyborem, origin oraz bearer. Nie publikuje zdjęcia, nie używa GPS, moderatora, upload journala ani cache. Domyślna aktywacja klienta pozostaje false; nie połączono go jeszcze z Runtime ani ekranem.

## Wejście i korelacja

GatewayAvatarOwnerPreviewQuery ma lokalne expected ownerID oraz niezmienny GatewayAvatarPublishIntent jako metadane wyboru. Ponowne użycie tego typu nie oznacza zgody na publikację. Wire usuwa consentVersion i nie wysyła właściciela: zawiera tylko requestID/versionID/generation/reviewRevision, do 512 B. Serwer nadal ustala właściciela z własnej sesji. Lokalny ownerID służy wyłącznie sprawdzeniu, czy odpowiedź pochodzi dla oczekiwanego konta. Przyszły host musi wyprowadzić go z aktualnego natywnego bindingu, a nie z dowolnego profilu.

Klient korzysta wyłącznie z POST /v1/community/avatar/preview na zatwierdzonym HTTPS origin. Bearer przechodzi kontrolę zamkniętego natywnego formatu. Content-Type JSON, Accept image/jpeg/application/json, identity encoding, no-store i dokładna długość body nie ujawniają lokalizacji ani URL dostawcy.

Przed buforowaniem transport sprawdza kod, no-store/private, nosniff, media/encoding/range/długość, pełny zamknięty manifest i X-Echoes-Avatar-Selection. Właściciel i wersja manifestu muszą pasować do query, a wszystkie cztery pola selection i schemaVersion=1 muszą być dokładne. Receipt moderatora jest zabroniony. Aliasy nagłówków, dodatkowe/brakujące pola, nieprawidłowe typy i nieskorelowana rewizja odmawiają dostępu. Nie ma 204 ani użycia poprzedniego obrazu po odmowie.

Body jest ograniczone do zatwierdzonego byteCount (maks. 256000 B / 512 px); sprawdzane są pełna długość, SHA-256 i znaczniki JPEG. Ten sam kontrakt jest powtórzony po wstrzykniętym transporcie. NativeGatewayAvatarDecoder wykonuje dekodowanie poza UI aktorem, kontroluje pełność pojedynczego obrazu i właściwości ImageIO. Zgodny hash samego uszkodzonego JPEG nie wystarcza. Wynik musi nadal mieć oczekiwany manifest i wymiary.

## Efemeryczny wynik i transport

GatewayAvatarOwnerPreview zawiera zweryfikowane piksele, dokładne query i wewnętrzne powiązanie z origin/fingerprint bearer. Opis i Mirror result/query są redacted. Nie zapisuje JPEG/obrazu na dysk, do Keychain ani do współdzielonego avatar cache. Nie jest to obietnica fizycznego wymazania kopii RAM lub prywatności dowolnego kodu, któremu przekazano publiczny CGImage.

Nieodnawialne okno 30 s rozpoczyna się przed siecią i obejmuje dekodowanie. Walidacja wymaga zgodnego czasu ściennego i monotonicznego, bez cofnięcia, oraz wieku mniejszego niż 30 s w obu zegarach. Kontrole po sieci/dekoderze odrzucają wygasły wynik, anulowanie i utratę aktywacji. Ponowne validate nie przedłuża okna. Inny bearer, origin lub wybór również unieważnia powiązanie. To lokalne ograniczenie ważności obrazu, nie server grant ani dowód wyświetlenia/zgody.

Transport ma własną ephemeral URLSession, bez cookies, credentials, URLCache, redirect i aplikacyjnej pętli retry. Jedna niezakończona operacja blokuje kolejną do powrotu transportu. Request timeout to 15 s, resource timeout 20 s, bez waitsForConnectivity; limit ważności wyniku pozostaje liczony przed żądaniem. Body/status i wymagane nagłówki są kontrolowane przed EOF; transport nie czeka na resztę niedozwolonego pliku. Wymusza też zgodność końcowego URL. Po zakończeniu anuluje task strumienia. Te kontrole nie są globalnym limiterem wszystkich klientów aplikacji — wspólny slot hosta i limity serwera nadal są potrzebne.

Błędy mają zamknięty UTF-8 JSON do 2048 B i właściwy code/status. Quota/busy/notFound pozostają odrębne od wymogu logowania; tylko kody sesji/wyłączonego konta/usuwania kierują do ponownego logowania. Retry-After jest ograniczony do 86400 s i nie powoduje samoczynnego ponowienia.

## Dowody i następny krok

[Raport etapu](evidence/avatar-owner-preview-native-local-tests.json) zapisuje SHA i rzeczywiste wyniki. Nowych 19 funkcji to 12 testów API i 7 URLSession: osiem konkretnych odpowiedzi lokalnego edge/Authority/Runtime/SQLite/policy, dekodowanie approved/reapproved, brak peer access, pełna korelacja, uszkodzone nagłówki/JPEG, limity/odmowy, oba zegary, okres obejmujący decode, cancellation/disable oraz binding/redaction. Testy URLProtocol wykorzystują prawdziwą ephemeral URLSession: redirect bez przekazania bearer, obcy URL, odrzucenie przed EOF, ograniczenie strumienia błędu, jeden slot/anulowanie i brak offline fallback/cookies/cache.

Końcowy pakiet ma 534 zdefiniowane testy: 532 zaliczone i 2 jawne sprzętowe skipy na Macu oraz iPhone 17 Pro Simulator. Debug i niepodpisany Release kompilują się; testowe fixtures nie są osadzone w aplikacji. Strict swift-format obejmuje pięć nowych plików. Negatywna odizolowana kopia bez kontroli reviewRevision oblewa dokładnie jeden test/jeden problem, a SHA oryginałów pozostają zgodne. Eksporter wygenerował osiem odpowiedzi oraz syntetyczny JPEG 2446 B; nowy skrypt przeszedł syntax Node22/24. Poprzedni serwerowy 538/538 pozostaje dowodem niezmienionego kodu produkcyjnego gateway, bez jego zbędnego powtarzania.

Tożsamości, platforma i Apple/CloudKit w fixture są modelami. URLProtocol nie jest rzeczywistym hosted HTTPS/Free. Dwa sprzętowe skipy nie są odbiorem ochrony fizycznego telefonu. Brak nowej aktywacji/usług/uprawnień/sekretów/opłat, SDK telefonu, Production/Firebase/TestFlight. Zastana zmiana projektu Xcode zachowana; bieżące kompilacje używają kontrolowanej kopii committed projektu. Niezwiązane wcześniejsze ostrzeżenia ramek UI nadal są otwarte.

Następny CK-04e.3j.3c.4c.3 musi dodać host właściciela z natywnym/prywatnym/lifecycle/parent scope, jednym retained slotem do końca decode, opaque bieżącym obrazem i wygaszeniem. Następnie edytor musi rzeczywiście wyświetlić ten dokładny obraz, potwierdzić jego obecność i uzyskać osobną zgodę autora przed trwałym publish intent. API nie zastępuje tych wymagań; publikacja bez upload journala nadal pozostaje zamknięta w interfejsie. Nadal obowiązuje pełny rzeczywisty odbiór i pozostały plan migracji; standardowe wejście nadal używa Firebase.
