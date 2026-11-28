# R-03a — host uploadu potwierdzony przez Apple

Po odpowiedzi właściciela „zgadzam sie/potwierdzam” przyjęto węższy limit **jednej próby** z [przygotowanej serii](ZAKRES_SERII_GRANTOW_DEVELOPMENT.md), SHA c222707f…. Wykonano pierwszy inwentarz SHA978ddde5… kodem `4d9aa7a`. Proces zakończył się kodem0; permit usunięto, attempt i raport zachowano prywatnie. Pozostałych dwóch inwentarzy nie uruchomiono i nie ma na nie przyjętego limitu.

Apple zwróciło poprawne granty obu pól `image` i `thumbnail` na dokładnym hoście **cws.icloud-content.com**. Oba adresy wymagały normalizacji authority i oba zawierały jawny domyślny port443. Potwierdza to obsługę tego wariantu w bieżącej odpowiedzi; surowych URL poprzedniej próby fac1e300… nie zachowano, więc jej dokładnej różnicy nadal nie znamy.

Wykonano1request `assets/upload`, **0uploadów bajtów, 0zapisów/usunięć rekordów i 0połączeń do otrzymanych adresów**. Nie zapisywano rawURL, tokenów ani body; [publiczny dowód](evidence/asset-grant-hosts-development-acceptance.json) zawiera wyłącznie hosty/liczniki i hashe prywatnych dowodów. Cloudflare, telefon i Production pozostały poza próbą. Tymczasowe granty mogą pozostać po stronie Apple.

To zalicza rozpoznanie hosta uploadu, nie przesłanie/odczyt zdjęcia, host pobierania, chroniony Runtime, A/B lub całość R-03. Domyślne listy hostów aplikacji nadal są puste. Następny krok według [planu R-03](PROBA_ASSET_DEVELOPMENT_PLAN.md): przygotować oddzielny rzeczywisty test dwóch małych syntetycznych JPEG, istniejącego normalizatora/uploadera/repozytorium, manifestów/SHA, własnego CAS i dokładnego sprzątania. Nie dotykać globalnego checkpointu; użyć izolowanego inwentarza i nie utożsamiać usunięcia rekordu z fizyczną retencją Apple/CDN. Dopiero po przygotowaniu narzędzia i lokalnych testach przedstawić osobny zakres zgody.

Nie zmieniono kodu gateway/iOS w tym etapie i nie powtarzano niezmienionych995testów. Weryfikacja rzeczywista: zgodność109plików źródeł/skryptów z przetestowanym commitem, terminalny wynik procesu, jeden intent/result, brak permitu i brak attempt dwóch pozostałych inwentarzy.
