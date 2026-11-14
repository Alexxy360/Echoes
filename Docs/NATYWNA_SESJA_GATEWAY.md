# Natywny klient sesji — CK-02j

Stan: 14 listopada 2026. Dodano implementację w pakiecie EchoesCloudKit, lokalne testy oraz izolowaną kontrolę systemowego Keychain w aplikacji Debug. **Nie podłączono jeszcze logowania do zwykłego interfejsu, nie aktywowano nowej bramki ani Sign in with Apple.** Zwykły CommunityClient nadal używa Firebase; ten etap nie zamyka CK-02 ani migracji.

## Co działa w kodzie

`GatewayHTTPClient` obsługuje zamknięte trasy challenge/login/renew/session/logout/logout-all protokołu CK-02i. Konfiguracja wymaga jawnego origin HTTPS bez portu, ścieżki, danych logowania, query lub fragmentu. Nie ma domyślnego URL do usługi diagnostycznej. Tokeny są nieprzezroczystymi wartościami o ograniczonym rozmiarze, nigdy parametrami URL. Nie odtwarzamy formatu HMAC serwera w UI.

`NativeGatewayTransport` używa efemerycznego URLSession bez cookie jar, cache i magazynu poświadczeń. Odrzuca przekierowania; nie przesyła kodu Apple lub bearer do nowego adresu. Sprawdza URL odpowiedzi, limit Content-Length oraz rzeczywisty strumień do 32 KiB; anuluje zadanie po zakończeniu/odrzuceniu odpowiedzi. Timeout zasobu wynosi 30 s. Klient sprawdza protocolVersion=1, daty/identyfikatory i typ JSON. Znane kody błędów/retry-after są ograniczone; obcy tekst błędu nie trafia do komunikatu. Nie dodano automatycznych ponowień kodów ani rotacji.

`GatewaySecret` redaguje interpolację, opis debug i reflection. Codable nadal zawiera właściwą wartość — to jest konieczne do HTTP i Keychain. **Nie wolno logować JSON żądań, par sesji, zrzutów storage ani Apple credential.** Nie jest to obietnica wyzerowania wszystkich kopii String w pamięci.

`KeychainGatewaySessionStorage` atomowo zastępuje pojedynczy rekord zawierający obydwa tokeny. Używa WhenUnlockedThisDeviceOnly, bez synchronizacji iCloud, z osobną przestrzenią pochodzącą ze skrótu origin. Dostępność jest zgodna z ograniczeniem działania klienta na pierwszym planie; brak dostępu do Keychain nie przełącza na UserDefaults lub plik. [Dostępność Keychain — Apple](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly).

`GatewaySessionController` jest aktorem. Współbieżni klienci oczekują na jedno odnowienie. Przed wysłaniem jednorazowego renewal tokenu zapisuje trwały stan renewalPending **bez starego tokenu**. Po utracie odpowiedzi lub restarcie nie wysyła go ponownie i wymaga nowego logowania. Obie nowe wartości są zapisywane razem przed udostępnieniem dostępu. Konto serwera i bezwzględny termin renewal nie mogą zostać podmienione/wydłużone przez rotację.

Wylogowanie zapisuje trwały stan signedOut przed siecią. Osobny wynik localOnly oznacza, że serwer nie potwierdził operacji — nie jest przedstawiany jako unieważnienie innych urządzeń. Po restarcie można odwołać znaną zapisaną sesję bez przywracania jej dostępu; nieznanego wyniku wcześniejszej rotacji nie uznajemy za potwierdzone wylogowanie serwera. Błąd zapisu Keychain blokuje używanie tokenów w bieżącym procesie i zgłasza błąd. Jeśli trwałego zapisu nie udało się wykonać, nie można obiecać zachowania wylogowania po restarcie.

Revision odcina spóźnione wyniki logowania/rotacji po wylogowaniu lub zmianie konta. Jeśli stary wynik zawiera nowy grant, kod próbuje go odwołać; nie jest to gwarancja udanego połączenia. Anulowany konsument nie otrzymuje tokenu i nie anuluje wspólnego odnowienia pozostałych konsumentów.

`GatewayIdentityBinding` oddziela Apple user ID, lokalny skrót CloudKit userRecordName i serwerowy accountID. Host **musi** sprawdzić natywny credentialState i konto CloudKit przed restore oraz natychmiast zablokować własny interfejs/cache przy ich zmianie. Sam zapis binding nie dowodzi aktualnego logowania. Host i obserwowanie zmian to następny etap.

`AppleGatewayAuthorizationAttempt` przygotowuje natywny request bez zakresów name/email. Podaje Apple SHA-256 **UTF-8 surowego napisu nonce otrzymanego od serwera**, a nie odkodowanych bajtów base64url. Osobny losowy state wiąże odpowiedź z próbą; próba jest jednorazowa i ma termin wyzwania. Helper sprawdza rodzaj danych, state, brakujące code/token oraz anulowanie; autentyczność JWT nadal weryfikuje serwer. Nie prezentuje jeszcze arkusza Apple i nie nadaje aplikacji capability. [Request nonce/state — Apple](https://developer.apple.com/documentation/authenticationservices/asauthorizationopenidrequest), [credential state — Apple](https://developer.apple.com/documentation/authenticationservices/asauthorizationappleidcredential/state).

## Weryfikacja

- **44/44 testy Swift na macOS**: 21 istniejących oraz 23 nowe, dane syntetyczne. Obejmują pary i odtworzenie, single-flight/anulowanie, późne wyniki, restart w trakcie rotacji, zmianę Apple/iCloud, błąd storage, wylogowanie bez potwierdzenia i po restarcie, podmienione konto, kontrakt HTTP i state/nonce Apple.
- Dwie nowe próby używają rzeczywistego URLSession z kontrolowanym URLProtocol w procesie: przekierowanie nie dociera do drugiego origin, odpowiedzi z zadeklarowanym i niezadeklarowanym zbyt dużym body są odrzucane. To nie jest test TLS lub prawdziwego hostingu.
- **Kontrola Security.framework w hoście Debug na symulatorze iPhone 17 Pro/iOS 26.1: passed.** Odczyt/zastąpienie danych, atrybut WhenUnlockedThisDeviceOnly, synchronizable=false i usunięcie wyłącznie losowego wpisu diagnostycznego. Nie używa prawdziwej tożsamości, sieci, GPS ani Muzyki. Nie testuje blokady/restartu/backupu fizycznego iPhone'a.
- Debug i Release aplikacji kompilują się dla iOS Simulator. Nie wykonano archiwum/instalacji na telefonie, Apple login/refresh/revoke ani operacji CloudKit/Cloudflare.

Pierwsza próba systemowego Keychain w samodzielnym runnerze testów Swift Package zakończyła się storageUnavailable; nie uznano jej za sukces. Runner po wyniku nie kończył się i został zatrzymany. Test przeniesiono do faktycznego hosta aplikacji, gdzie przeszedł. Nie osłabiono ustawień Keychain ani obsługi błędów, aby dopasować je do runnera.

Powtarzalna kontrola lokalna: zbudować Debug, uruchomić w symulatorze z `ECHOES_GATEWAY_STORAGE_CHECK=1`. Ekran/pole `gateway.storage.result` i konsola pokazują wyłącznie stały wynik; `passed` wymaga także pomyślnego cleanup. Tryb jest wycięty z Release i nie inicjalizuje Firebase. Nie służy do testowania logowania. [Dowody](evidence/native-gateway-session-tests.json).

## Pozostałe warunki odbioru

1. Host logowania Apple: prezentacja arkusza, natywny credentialState/revocation, konto CloudKit, cykl pierwszego planu oraz wyczyszczenie widoków/cache. Sign in with Apple App ID/klucz i rzeczywisty URL bramki wymagają osobnego przygotowanego zakresu konfiguracji; nie tworzono ich tutaj.
2. Odzyskanie dostępu po pięciu utraconych grantach: backend obecnie zwraca SESSION_LIMITED. Potrzebny jest świadomy reset poprzednich sesji ze świeżym dowodem Apple. Klient nie obchodzi tego limitu i nie wylogowuje innych urządzeń bez wyboru użytkownika.
3. Klient biletu usuwania i prywatny cleanup CloudKit, prawdziwy adapter publicznych danych, profile/avatar, mapa/czat i moderacja nadal wymagają implementacji. Ta warstwa auth nie udaje CommunityClient.
4. Kontrolowane próby Apple/Workers/urządzenia, limitów/awarii oraz dwóch zwykłych kont i oddzielnej tożsamości serwera pozostają obowiązkowe. Nie zastępuje ich test operatora lub dane syntetyczne.
