;; Contract: route-schedule-and-gtfs-attestation
;; Purpose: Publish signed GTFS schedules and route changes with versioned histories.
;; Notes:
;;  - No cross-contract calls or trait usage.
;;  - Focuses on simple, transparent publication and attestation metadata.
;;  - Provides versioned history by (route, version) and per-schedule-id snapshots.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Constants and Errors
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-constant ERR_UNAUTHORIZED u100)          ;; caller not allowed
(define-constant ERR_ALREADY_INITIALIZED u101)    ;; initialize called twice
(define-constant ERR_NOT_FOUND u404)              ;; record not found
(define-constant ERR_VERSION_CONFLICT u409)       ;; same (route, version) exists
(define-constant ERR_BAD_INPUT u400)              ;; invalid parameters

(define-constant MAX-ROUTE-NAME 32)         ;; Note: cannot use in type signatures
(define-constant MAX-NOTES 100)              ;; Note: cannot use in type signatures

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; State
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Admin must call (initialize) once to set themselves as admin.
(define-data-var admin (optional principal) none)

;; Publishers are allowed to publish and deprecate schedules.
(define-map publishers principal bool)

;; Auto-incrementing identifier for schedules.
(define-data-var next-schedule-id uint u1)

;; Primary schedule storage keyed by schedule id.
(define-map schedules
  { id: uint }
  {
    route: (string-ascii 32),
    version: uint,
    hash: (buff 32),              ;; content hash of the GTFS payload or manifest
    publisher: principal,         ;; who published this schedule
    notes: (string-ascii 100),
    timestamp: uint,              ;; unix epoch seconds supplied by caller
    signature: (buff 65),         ;; optional ECDSA signature bytes (opaque)
    active: bool                  ;; can be deprecated later
  }
)

;; Snapshot of specific (id, version) content.  Useful if the same id is updated
;; with metadata later. Typically we keep id-per-publish, but this allows rich history.
(define-map schedule-versions
  { id: uint, version: uint }
  {
    hash: (buff 32),
    notes: (string-ascii 100),
    timestamp: uint
  }
)

;; Index that ensures (route, version) is globally unique and maps to an id.
(define-map route-version-index
  { route: (string-ascii 32), version: uint }
  { id: uint }
)

;; Latest known id/version for a specific route.
(define-map route-latest
  { route: (string-ascii 32) }
  { id: uint, version: uint }
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-private (is-admin (who principal))
  (match (var-get admin)
    admin-p (is-eq who admin-p)
    false
  )
)

(define-private (is-publisher (who principal))
  (default-to false (map-get? publishers who))
)

(define-private (authorized (who principal))
  (or (is-admin who) (is-publisher who))
)

(define-private (assert-authorized)
  (if (authorized tx-sender)
      (ok true)
      (err ERR_UNAUTHORIZED))
)

(define-private (assert-admin)
  (if (is-admin tx-sender)
      (ok true)
      (err ERR_UNAUTHORIZED))
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Public Administration
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (initialize)
  (begin
    (if (is-some (var-get admin))
        (err ERR_ALREADY_INITIALIZED)
        (begin
          (var-set admin (some tx-sender))
          (ok true)
        )
    )
  )
)

(define-public (add-publisher (who principal))
  (begin
    (try! (assert-admin))
    (map-set publishers who true)
    (ok true)
  )
)

(define-public (remove-publisher (who principal))
  (begin
    (try! (assert-admin))
    (map-delete publishers who)
    (ok true)
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Publishing API
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (publish-schedule
  (route (string-ascii 32))
  (hash (buff 32))
  (version uint)
  (notes (string-ascii 100))
  (timestamp uint)
  (signature (buff 65))
)
  (begin
    (try! (assert-authorized))
    ;; prevent duplicates by (route, version)
    (if (is-some (map-get? route-version-index { route: route, version: version }))
        (err ERR_VERSION_CONFLICT)
        (let (
          (id (var-get next-schedule-id))
        )
          (map-set schedules { id: id }
            {
              route: route,
              version: version,
              hash: hash,
              publisher: tx-sender,
              notes: notes,
              timestamp: timestamp,
              signature: signature,
              active: true
            }
          )
          (map-set schedule-versions { id: id, version: version }
            { hash: hash, notes: notes, timestamp: timestamp }
          )
          (map-set route-version-index { route: route, version: version } { id: id })
          (map-set route-latest { route: route } { id: id, version: version })
          (var-set next-schedule-id (+ id u1))
          (print { event: "publish", id: id, route: route, version: version, publisher: tx-sender })
          (ok id)
        )
    )
  )
)

(define-public (deprecate-schedule (id uint))
  (begin
    (try! (assert-authorized))
    (match (map-get? schedules { id: id })
      s
        (begin
          (map-set schedules { id: id } (merge s { active: false }))
          (print { event: "deprecate", id: id, by: tx-sender })
          (ok true)
        )
      (err ERR_NOT_FOUND)
    )
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Read-only Queries
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-read-only (get-admin)
  (var-get admin)
)

(define-read-only (is-authorized-publisher (who principal))
  (default-to false (map-get? publishers who))
)

(define-read-only (get-schedule (id uint))
  (map-get? schedules { id: id })
)

(define-read-only (get-version (id uint) (version uint))
  (map-get? schedule-versions { id: id, version: version })
)

(define-read-only (get-latest-for-route (route (string-ascii 32)))
  (map-get? route-latest { route: route })
)

(define-read-only (get-id-for-route-version (route (string-ascii 32)) (version uint))
  (map-get? route-version-index { route: route, version: version })
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Notes
;; - This contract intentionally does not verify cryptographic signatures on-chain
;;   to keep the implementation simple. The `signature` field is stored as opaque
;;   bytes for off-chain validation or future enhancements.
;; - Timestamps are provided by the caller. Depending on governance, an oracle or
;;   off-chain indexer could validate them.
;; - The design avoids iteration by maintaining explicit indexes and counters.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
