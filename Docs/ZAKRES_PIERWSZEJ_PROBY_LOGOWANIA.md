# R-04c.1b — zakres do zatwierdzenia: pierwsze logowanie na telefonie

Przygotowano po lokalnym R-04c.1a, 21 listopada 2026. To propozycja; nie aktywowano jej. [Plan i granice dowodu](PIERWSZA_PROBA_LOGOWANIA_PLAN.md). Cel: jedno rzeczywiste logowanie właściciela, odtworzenie Keychain po restarcie, rotacja sesji po jej rzeczywistym wygaśnięciu i logout-all. Pełne serwerowe refresh/revoke Apple pozostają dalszą bramką, bez zmiany polityki24h.

## Odbiorca i czas

Istniejąca usługa `echoes-community-development`, WorkersFree, adres `https://echoes-community-development.2rnd2bt6rd.workers.dev`, namespace SQLite `c56ebf43cfc246edb56e6615987b4c57`, instancja `echoes-auth-authority-development-v1`. Najpierw potwierdzić wyłączoną konfigurację/brak kont i gotowość telefonu. Następnie jedno wspólne okno **do45min**, z tym samym terminem UTC w backendzie i podpisanym pakiecie Debug. Nie przedłużać okna automatycznie i nie ponawiać interaktywnego logowania. Sprzątanie tego przebiegu może trwać do2h od startu, bez ponownej aktywacji HTTP.

Włączyć wyłącznie `GATEWAY_ENABLED=1` oraz workers.dev na czas próby. `ACCOUNT_DELETION_ENABLED`, `PUBLIC_RECORDS_ENABLED`, `COMMUNITY_ENABLED`, retencja i wszystkie funkcje Avatar/Review pozostają0. Bez klucza CloudKit w Cloudflare, bez dostępu do profilu/zdjęć/GPS/Muzyki, bez nowych typów/rekordów CloudKit lub Production. Baza prywatna służy wyłącznie natywnemu sprawdzeniu dostępności/tożsamości iCloud; nie zapisujemy ani nie usuwamy jej danych.

## Sekrety i uprawnienia

Przekazać **tylko tej usłudze Cloudflare** cztery secret bindings:

| Binding | Dokładny materiał i uprawnienie |
| --- | --- |
| APPLE_SIGNIN_PRIVATE_KEY | Dotychczasowy klucz SIWA `QPBMSAY553` dla primary `mpvEcho.Echo`, zespołu `22YC9RAP4P`. Pozwala podpisywać client_secret dla tego App ID; w połączeniu z odpowiednim kodem/tokenem pozwala na operacje OAuth. Nie ma technicznego podziału Development/Production |
| REFRESH_KEYS_JSON | Jeden nowy losowy klucz256bit AES-GCM, IDv1, do szyfrowania refresh tokenu w tym magazynie |
| RENEWAL_KEYS_JSON | Oddzielny nowy losowy klucz256bit integralności proof, IDv1 |
| REQUEST_BUDGET_KEY | Trzeci oddzielny losowy klucz256bit HMAC limitów sieciowych |

Publiczny `APPLE_SIGNIN_KEY_ID=QPBMSAY553` nie jest sekretem. Materiał prywatny przygotować lokalnie w plikach0600/katalogu0700 poza Git/aplikacją i przekazać po tej konkretnej zgodzie. Cloudflare otrzyma także jednorazowy code i identity token Apple podczas logowania, a serwer przechowa zaszyfrowany refresh token, pseudonim konta i metadane sesji. Aplikacja nie żąda name/email; nie obiecywać, że sam token Apple nigdy nie zawiera dodatkowych claims. Kod nie zapisuje tych claims jako profilu. Wartości tokenów, request JSON i odszyfrowany refresh nie trafiają do konsoli ani repo.

Utworzyć najwyżej jeden nowy tymczasowy token wdrożenia `Individual Workers Editor`, ograniczony wyłącznie do tej usługi. Użyć go lokalnie poza Git do konfiguracji sekretów/terminu i kontroli, a następnie unieważnić po próbie, również po błędzie. Nie przyjmować szerszego zakresu ani tworzyć kolejnych tokenów automatycznie. Nie zmieniać planu Free, karty lub innych usług.

## Telefon i przebieg

Użyć istniejącego ważnego certyfikatu Apple Development (Team OU potwierdzone lokalnie), bez tworzenia nowego certyfikatu. Zaktualizować profil podpisywania dla `mpvEcho.Echo` / zespołu22YC9RAP4P z już zatwierdzonym iCloud/CloudKit i Sign in with Apple. Zainstalować podpisany Debug na dotychczasowym **iPhonie15Pro**, zastępując wersję deweloperską bez odinstalowania lub kasowania jej danych. Użyć przygotowanego wariantu Info.plist; aktywacja zmienia tylko enabled/termin, z ustalonym origin i kontenerem. Wersja próby ukrywa funkcje społecznościowe i usuwanie profilu. Nie zmieniać Apple ID, konta iCloud ani istniejącej zgody GPS/Muzyki.

Właściciel sam potwierdza arkusz Apple/FaceID i później zatrzymuje używanie SIWA dla testowego Echoes w ustawieniach Apple. Nie podaje hasła/kodu w czacie. Najwyżej jedno interaktywne logowanie, jedno zimne odtworzenie przed wygaśnięciem, jedno odnowienie po rzeczywistych10min i logout-all. Bez celowej utraty odpowiedzi, dodatkowego konta lub ponawiania code. Ograniczyć aplikacyjne żądania kontrolne do30, bez automatycznego retry. Testowy UUID konta z ekranu/prefiksu konsoli jest prywatnym identyfikatorem do powiązania cleanup; lokalny raport0600 poza Git, publiczny raport zawiera tylko wynik zgodności i skrót.

## Sprzątanie i kontrola

Po zatrzymaniu klienta wyłączyć workers.dev/aktywację, uzyskać od właściciela potwierdzenie odwołania zgody Apple dla Echoes i wykonać dokładny inwentarz jedynego nowego konta. Nie odczytywać wartości sekretów. Przy drugim koncie, pending reservation/lease, banie, zadaniu usuwania lub checkpoint publicznym zatrzymać SQL mutacje.

`gateway/scripts/authentication-trial-cleanup-plan.mjs` tworzy prywatny plan z UUID konta potwierdzonym na telefonie, subjectHash i credentialID odczytanymi dla dokładnie tego konta. Przed mutacjami wymagać `eligible=1`. Siedem osobnych DELETE ponownie sprawdza zakres i usuwa wyłącznie jego challenge, sessions, renewal grants, apple state, zaszyfrowane credential, reset fence, następnie samo konto po sprawdzeniu nieobecności pozostałych własnych wierszy. Nie usuwać namespace, tabel, innych kont, anonimowych liczników lub nieznanych challenges. Późniejsze osiem count musi potwierdzić0. Limit sprzątania:40zdalnych instrukcji SQL, bez polecenia arbitralnego lub resetu bazy. Po błędzie zachować pending i dokładny prywatny inwentarz, nie deklarować sukcesu.

Usunąć cztery sekrety z aktywnej wersji, ponownie sprawdzić flagi0/brak trasy, unieważnić tymczasowy token i usunąć jego lokalną kopię. **Klucz SIWA QPBMSAY553 pozostaje zarejestrowany w Apple do dalszej migracji. Przekazanie go Cloudflare jest trwałym powierzeniem sekretu temu usługodawcy**: historyczne wersje/PITR mogą przechować kopie, a usunięcie bindingu tworzy nową wersję i nie jest dowodem wymazania historii. Okno45min ogranicza działanie testowanej usługi, nie czas posiadania kopii klucza. Nie tworzyć klucza zastępczego ani nie unieważniać QPBMSAY553 w tym zakresie. Nie odinstalowywać aplikacji lub usuwać dawnych danych Firebase.

Nie przedstawiać ręcznej czynności właściciela jako udanego wywołania `/auth/revoke`. Odbiór serwerowego refresh/revoke, dwóch zwykłych kont A/B, danych społecznościowych i całej migracji pozostaje otwarty. [Apple: zarządzanie SIWA](https://support.apple.com/en-gb/102571), [Cloudflare: wersje i bindings](https://developers.cloudflare.com/workers/versions-and-deployments/), [sekrety](https://developers.cloudflare.com/workers/configuration/secrets/).
