# Wymiana kodu Apple i ochrona tokenów — CK-02f

Stan: 13 listopada 2026. Kod lokalny, połączony z koordynatorem logowania i testami SQLite. Nie wdrożono go do Workers/iOS, nie wykonano prawdziwej wymiany kodu ani nie utworzono klucza Sign in with Apple. Diagnostyczny Worker nadal jest wyłączony i nie ma sekretów w aktywnej wersji.

## Kontrakt Apple

`AppleClientSecret` wymaga osobnego klucza Sign in with Apple PKCS#8 P-256 i jego key ID. Generuje ES256 JWT z podpisem raw r||s, stałym zespołem 22YC9RAP4P, App ID mpvEcho.Echo, odbiorcą Apple i terminem 5 min. To inny klucz i format podpisu niż CloudKit S2S. Algorytm realizuje node:crypto; test sprawdza podpis niezależnym verify. [Tworzenie client secret wskazane przez dokumentację Sign in with Apple](https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret), [format podpisu i błędy Apple](https://developer.apple.com/documentation/technotes/tn3107-resolving-sign-in-with-apple-response-errors).

`AppleOAuthClient` ma trzy wewnętrzne operacje: wymianę kodu, walidację refresh tokenu i odwołanie refresh tokenu. Używa wyłącznie https://appleid.apple.com/auth/token lub /auth/revoke, formularza URL-encoded i stałego client_id. Nie dodaje redirect_uri, ponieważ przygotowywany przepływ jest natywny, bez początkowego redirect_uri. Nie obsługuje dowolnego URL/Services ID podanego przez klienta. [Protokół wymiany i refresh](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens).

Każda operacja ma limit 5 s obejmujący sieć i ciało odpowiedzi, do 64 KiB, ścisły UTF-8/JSON, ograniczone rozmiary tokenów i brak podążania za przekierowaniem. Błędy mają zamknięte kody, bez error_description, przyczyny, kodu autoryzacyjnego, tokenu czy klucza. Nie ma automatycznych ponowień. Access token jest walidowany i pomijany w wyniku adaptera. Wynik wymiany zawiera ID token i refresh token wyłącznie do wewnętrznego przetworzenia; nie jest odpowiedzią HTTP dla aplikacji.

Refresh może zwrócić nowy token lub sam ID token. Ten adapter tylko realizuje protokół transportowy: **nie wydaje nowej sesji na podstawie refresh i nie zastępuje weryfikacji tożsamości**. Weryfikacja odnowionej tożsamości i rotacja wymagają osobnego przepływu; polityki nonce/świeżości pierwotnego logowania nie należy kopiować do niego bez analizy. Odwołanie uznaje wyłącznie pustą odpowiedź 200; ponowne odwołanie już unieważnionego tokenu ma taki sam wynik według [Apple Token revocation](https://developer.apple.com/documentation/signinwithapplerestapi/revoke-tokens).

## Zaszyfrowany magazyn i sesja

`RefreshCredentialVault` używa AES-256-GCM przez node:crypto, losowego 96-bitowego IV i 128-bitowego tagu. Wersja envelope oraz AAD wiążą ciphertext z App ID, UUID wyzwania/credential, skrótem zweryfikowanego sub i ID klucza. Podmiana tokenu między kontami lub wyzwaniami nie przechodzi uwierzytelnienia. Błędy nie eksportują danych. Plaintext istnieje przejściowo w pamięci procesu; kod nie obiecuje wyzerowania stringów JavaScript.

Klucz szyfrowania to oddzielny losowy sekret 256-bitowy, nie klucz Apple ani CloudKit. Musi pochodzić z sekretów serwera. Nie ma wygenerowanego domyślnego klucza ani fallbacku plaintext. Magazyn potrafi odczytać do trzech wersji i ponownie zaszyfrować wpis aktywną wersją; **nie ma jeszcze wdrożonego zadania rotacji**. Starego klucza nie wolno usunąć przed migracją wszystkich wpisów i sprawdzeniem możliwości odtworzenia. Szyfrowanie chroni kopię samych tabel, nie przejęty proces posiadający klucz i prawo odszyfrowania.

Przepływ koordynatora:

1. Zweryfikować token telefonu i trwale zarezerwować jednorazowe wyzwanie.
2. Jeden raz wymienić kod. Ponownie zweryfikować podpis/nonce/audience odpowiedzi Apple.
3. Zaszyfrować refresh token z kontekstem zweryfikowanej odpowiedzi. Zapisać `auth_refresh_credentials_v1` jako pending i potwierdzić trwałość.
4. Sprawdzić zgodność obu tożsamości. W jednej transakcji powiązać pending credential z kontem, zużyć wyzwanie i zapisać sesję. Brak credential lub inny subject blokuje transakcję.
5. Dopiero po sync zwrócić token sesji. Do klienta nie trafia refresh token, client_secret ani ID token z wymiany.

Tabela zawiera UUID, skrót sub, ciphertext, status pending/bound, wewnętrzne account_id i czas utworzenia. Sesja wskazuje credential przez ten sam UUID wyzwania. Nie przechowuje authorization code, ID/access tokenu ani surowego sub. Metody stage/complete są wyłącznie wewnętrzne i nie mogą stać się dowolnym dispatch/RPC z JSON klienta.

## Awarie i retencja przed wdrożeniem

- Nieznany wynik wymiany nie pozwala ponowić tego kodu. Nie ma transakcji obejmującej Apple i SQLite. Awaria przed poprawną weryfikacją/zapisem może pozbawić serwer refresh tokenu; nie obiecujemy jego odzyskania bez nowej autoryzacji.
- Błąd sync magazynu blokuje wydanie sesji; trwałość samego wpisu może być wtedy nieznana. Błąd końcowej transakcji pozostawia pending. Błąd jej sync może pozostawić bound i zapisaną sesję, której klient nie otrzymał. Testy rozróżniają te przypadki.
- Różne zweryfikowane sub nie wydają sesji. Zaszyfrowany pending zachowuje sub z odpowiedzi Apple i pozostaje do uzgodnienia; nie przypisujemy go drugiemu kontu.
- Wygaśnięcie wyzwania podczas wymiany blokuje sesję, ale pozwala zachować znany token jako pending. Cleanup nie kasuje claimed przez dodatkowe 24 h. Nie przywraca to prawa do logowania ani ponowienia kodu.
- Nie odwołujemy automatycznie zgody Apple po błędzie/limicie sesji: mogłoby to przerwać działające autoryzacje tego samego użytkownika. Logout aplikacji i odwołanie zgody Apple to różne operacje.
- Credential nie jest kasowany przez purgeExpired sesji. Przed HTTP wymagane są: kontrolowany proces odwołania/usuwania, rozwiązywanie pending/nieznanych wyników, limity liczby/przestrzeni wpisów i harmonogram retencji. Bez tego wielokrotne logowania mogą powiększać tabelę. Nie traktować szyfrowania jako zamiennika retencji.

## Dowody i dalszy odbiór

10 testów OAuth, 6 vault i 24 stanu/logowania (w tym 7 nowych integracyjnych). Pełna regresja gateway: **80/80** na Node 22.23.5. Żądania Apple zastępuje transport testowy; użyte klucze i tokeny są syntetyczne. Istniejąca regresja przekierowań używa loopback, bez Apple/Cloudflare. [Raport](evidence/apple-oauth-vault-local-tests.json).

Przed aktywacją nadal wymagane: konfiguracja Sign in with Apple i świadome nadanie klucza, ochrona/rotacja prawdziwych sekretów, opisany wyżej cykl credential, spójny routing/limity HTTP, natywny przepływ i Keychain, rzeczywisty test Apple, Workers/CPU oraz zwykłe konta A/B. Nie dodano żadnych uprawnień, kosztów, endpointów ani operacji na prawdziwych tokenach użytkownika.
