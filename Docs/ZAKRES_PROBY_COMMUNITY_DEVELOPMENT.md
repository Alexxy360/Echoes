# Przygotowany zakres operacji — CloudKit Community Development

19 listopada 2026. **Przygotowane do zatwierdzenia, jeszcze niewykonane.** Przyjęty model Individual nie jest zgodą na te operacje. [Narzędzie i granice](CLI_TESTU_PROTOKOLU_CLOUDKIT.md).

## Cel i kontekst

Sprawdzić rzeczywisty protokół ośmiu zaimportowanych typów: zapis, odczyt, conditional replace, usunięcie pól, konflikt starego tagu oraz warunkowe usunięcie własnych rekordów. Zespół `22YC9RAP4P`, kontener `iCloud.mpvEcho.Echo`, wyłącznie **Development/public**. Schemat odczytany po imporcie ma SHA256 `6ee9f8e03394b502839774280090718f8ead5ea7090e19063c8c7d4d8c111025`.

Inwentarz jest już przygotowany lokalnie i zamknięty w prywatnym dzienniku. SHA256 planu: **`529f04556a612b06513b5418186345dd53b0fef3114ae416c20790d0622fbd26`**. Osiem ID i komplet pól są w prywatnym `inventory.json`; nie przenosimy pełnego bieżącego inwentarza/permit/sekretów do Git. Samo prepare wykonało0żądań i nie aktywowało okna.

## Kolejność po uzyskaniu konkretnej zgody

1. Odczytać bieżącą listę kluczy i uprawnienia konta. Potwierdzić kontener/środowisko, znany stary klucz oraz dotychczasowe konto właściciela. Jeżeli pojawi się inny aktywny klucz tego kontenera i środowiska, którego skutków nie obejmuje zgoda, zatrzymać się przed nadaniem roli i przedstawić rozszerzony zakres. Nie zmieniać obcych kluczy lub kont.
2. Unieważnić wyłącznie starą rejestrację **„Echoes Development gateway probe 2026-11-12”**, ID `0663e7ddc1124c0522589f5db7d0786c19f80c35ac158199db561f6e79a80919`, Development. Potwierdzić brak aktywnej rejestracji w konsoli i zapisać dowód. Unieważnienie jest trwałe: stare lokalne kopie i ewentualne historyczne wersje Cloudflare nie będą mogły uwierzytelniać nowych żądań tym kluczem. Nie kasujemy Workerów, rekordów ani innych rejestracji.
3. Wygenerować lokalnie nową parę P-256 i zarejestrować publiczny klucz jako **„Echoes Community Development 2026-11-19”** wyłącznie dla tego kontenera/Development. Prywatny PEM0600 i metadane pozostają w osobnym katalogu0700 poza repozytorium, pod Application Support/Echoes. Przed kolejnymi commitami rozszerzyć kontrolę wycieków także o nowy klucz. Nie przekazywać prywatnego klucza Cloudflare, aplikacji iOS ani Git.
4. Przypisać istniejącą rolę **EchoesCommunityService wyłącznie dotychczasowemu kontu właściciela/administratorowi** w bazie Development. Potwierdzić dokładną tożsamość przez dotychczasowy identyfikator konta i stan UI. Zachować inne role i członkostwa. Nie zmieniać definicji schematu. Rola daje READ/CREATE/WRITE do ośmiu typów, a konto właściciela ma ten dostęp również z SDK poza ograniczeniami bramki do3km. Nowy klucz S2S dziedziczy uprawnienia twórcy w publicznej bazie, łącznie z jego pozostałymi istniejącymi prawami — ograniczenie do ośmiu syntetycznych ID egzekwuje lokalny wykonawca, nie sam klucz.
5. Dopiero po tych weryfikacjach uzupełnić prywatny permit konkretnymi nowymi keyID/publicSPKI i **jednym oknem do30min**, uruchomić jeden run przygotowanego inwentarza. Maksymalnie9wywołań batch po8rekordów. Preflight wymaga nieobecności wszystkich ID; dokładne odczyty, jeden create, replace z aktualnym tagiem, odczyt potwierdzający usunięcie treści, stary tag z pustym payloadem bariery, reconciliation, conditional delete i potwierdzenie nieobecności. Sprzątanie w tym samym oknie i limicie jest częścią próby. Brak automatycznej ponownej próby lub nowego okna.
6. Zapisać prywatny raport i zredagowane dowody w dokumentacji; opisać wynik każdego etapu i ewentualne cleanup-pending. Wyłączyć lokalny opt-in i zakończyć proces. Nowy klucz pozostaje lokalnie, a administracyjna rola pozostaje przypisana do dalszych uzgodnionych testów; nie aktywuje to hostowanej usługi. Nieznany wynik, upływ okna lub niedokończone sprzątanie wymagają jawnego raportu oraz osobno zatwierdzonego świeżego okna cleanup tego samego inwentarza. Nie ukrywamy pozostałych rekordów przez reset/usuwanie typu.

## Co ta próba zawiera

Wyłącznie syntetyczny pseudonim/tekst/powód zgłoszenia, losowy accountID/runID, stałe położenie0,0 bez odczytu GPS, avatar jako metadane bez binarnych plików lub pól ASSET. Checkpoint ma losowe ID testowe, różne od stałego checkpointu gateway. Operacje mogą trwale usunąć tylko własne rekordy tej zatwierdzonej próby, po identyfikacji i aktualnym tagu.

## Pozostające granice

Bez dostępu do prywatnej bazy profili, danych istniejących użytkowników, query całych typów, dokładnego GPS, Muzyki, zdjęć, uploadu, Cloudflare/nowych tokenów wdrożeniowych, zmian Production, publikacji/TestFlight i dodatkowych opłat. Nie usuwamy danych ani SDK Firebase. Odwołanie starego klucza nie usuwa jego historycznych kopii; odbiera im możliwość uwierzytelniania tym kluczem, co trzeba potwierdzić w panelu. Nie twierdzimy, że znamy zawartość wszystkich historycznych wersji Workerów.

Udana próba potwierdzi tylko protokół metadanych tych typów i klucza w Development. Nie potwierdzi izolacji zwykłych kont A/B, regionalnych zapytań/indeksów, ASSET/CDN, rzeczywistych limitów Free, SIWA lub gotowości wydania. Te warunki pozostają w pełnym planie.
