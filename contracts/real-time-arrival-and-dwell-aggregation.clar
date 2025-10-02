;; Contract: real-time-arrival-and-dwell-aggregation
;; Purpose: Aggregate AVL data into headway adherence, dwell times, and on-time scores.
;; Notes:
;;  - No cross-contract calls or trait usage.
;;  - Records per-arrival events and maintains simple per-route/day aggregates.
;;  - Threshold for on-time can be adjusted by admin; default is 5 minutes.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Constants and Errors
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-constant ERR_UNAUTHORIZED u200)
(define-constant ERR_ALREADY_INITIALIZED u201)
(define-constant ERR_NOT_FOUND u404)

;; Fixed literal sizes in type signatures (constants cannot be referenced in types)
(define-constant ROUTE-NAME-SIZE 32)      ;; Docs only
(define-constant STOP-NAME-SIZE 32)       ;; Docs only
(define-constant VEHICLE-NAME-SIZE 32)    ;; Docs only

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; State
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-data-var admin (optional principal) none)
(define-map operators principal bool)                 ;; who can submit AVL events
(define-data-var late-threshold-seconds uint u300)    ;; default: 5 minutes
(define-data-var next-arrival-id uint u1)

;; Each arrival event is recorded under a unique id.
(define-map arrivals
  { id: uint }
  {
    route: (string-ascii 32),
    stop: (string-ascii 32),
    vehicle: (string-ascii 32),
    ts-actual: uint,
    ts-scheduled: uint,
    deviation: int,            ;; actual - scheduled (seconds)
    abs-deviation: uint,       ;; absolute value of deviation (seconds)
    on-time: bool,
    dwell-seconds: uint,
    service-date: uint         ;; YYYYMMDD or epoch-day (user-provided)
  }
)

;; Aggregated stats per route/day to avoid iteration.
(define-map agg
  { route: (string-ascii 32), date: uint }
  {
    count: uint,
    ontime: uint,
    sum-deviation: int,       ;; signed sum
    sum-abs-deviation: uint,  ;; unsigned sum of absolute deviation
    total-dwell: uint
  }
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Helpers
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-private (is-admin (who principal))
  (match (var-get admin)
    a (is-eq who a)
    false
  )
)

(define-private (is-operator (who principal))
  (default-to false (map-get? operators who))
)

(define-private (authorized (who principal))
  (or (is-admin who) (is-operator who))
)

(define-private (assert-admin)
  (if (is-admin tx-sender) (ok true) (err ERR_UNAUTHORIZED))
)

(define-private (assert-authorized)
  (if (authorized tx-sender) (ok true) (err ERR_UNAUTHORIZED))
)

(define-private (abs-int (x int))
  (if (< x 0)
      (- x)  ;; negate: --x is not valid; - on int is unary negation when used with one arg
      x)
)

(define-private (abs-to-uint (x int))
  (to-uint (abs-int x))
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Administration
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (initialize)
  (begin
    (if (is-some (var-get admin))
        (err ERR_ALREADY_INITIALIZED)
        (begin (var-set admin (some tx-sender)) (ok true)))
  )
)

(define-public (add-operator (who principal))
  (begin
    (try! (assert-admin))
    (map-set operators who true)
    (ok true)
  )
)

(define-public (remove-operator (who principal))
  (begin
    (try! (assert-admin))
    (map-delete operators who)
    (ok true)
  )
)

(define-public (set-late-threshold-seconds (secs uint))
  (begin
    (try! (assert-admin))
    (var-set late-threshold-seconds secs)
    (ok secs)
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Recording API
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-public (record-arrival
  (route (string-ascii 32))
  (stop (string-ascii 32))
  (vehicle (string-ascii 32))
  (ts-actual uint)
  (ts-scheduled uint)
  (dwell-seconds uint)
  (service-date uint)
)
  (begin
    (try! (assert-authorized))
    (let (
      (diff (- (to-int ts-actual) (to-int ts-scheduled)))
      (absd (abs-to-uint (- (to-int ts-actual) (to-int ts-scheduled))))
      (thr (var-get late-threshold-seconds))
      (id (var-get next-arrival-id))
      (ontime (<= absd thr))
    )
      (map-set arrivals { id: id }
        {
          route: route,
          stop: stop,
          vehicle: vehicle,
          ts-actual: ts-actual,
          ts-scheduled: ts-scheduled,
          deviation: diff,
          abs-deviation: absd,
          on-time: ontime,
          dwell-seconds: dwell-seconds,
          service-date: service-date
        }
      )
      ;; update aggregates
      (let (
        (key { route: route, date: service-date })
      )
        (match (map-get? agg key)
          current
            (let (
              (new-count (+ (get count current) u1))
              (new-ontime (+ (get ontime current) (if ontime u1 u0)))
              (new-sum-dev (+ (get sum-deviation current) diff))
              (new-sum-abs (+ (get sum-abs-deviation current) absd))
              (new-dwell (+ (get total-dwell current) dwell-seconds))
            )
              (map-set agg key
                {
                  count: new-count,
                  ontime: new-ontime,
                  sum-deviation: new-sum-dev,
                  sum-abs-deviation: new-sum-abs,
                  total-dwell: new-dwell
                }
              )
            )
          (let (
            (new-count u1)
            (new-ontime (if ontime u1 u0))
          )
            (map-set agg key
              {
                count: new-count,
                ontime: new-ontime,
                sum-deviation: diff,
                sum-abs-deviation: absd,
                total-dwell: dwell-seconds
              }
            )
          )
        )
      )
      (var-set next-arrival-id (+ id u1))
      (print { event: "arrival", id: id, route: route, stop: stop, ontime: ontime })
      (ok id)
    )
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Read-only Queries
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define-read-only (get-admin)
  (var-get admin)
)

(define-read-only (is-operator-p (who principal))
  (default-to false (map-get? operators who))
)

(define-read-only (get-late-threshold-seconds)
  (var-get late-threshold-seconds)
)

(define-read-only (get-arrival (id uint))
  (map-get? arrivals { id: id })
)

(define-read-only (get-agg (route (string-ascii 32)) (service-date uint))
  (map-get? agg { route: route, date: service-date })
)

(define-read-only (ontime-rate-bps (route (string-ascii 32)) (service-date uint))
  ;; returns basis points (0..10000) of on-time rate for the given key
  (match (map-get? agg { route: route, date: service-date })
    a
      (let (
        (count (get count a))
        (ontime (get ontime a))
      )
        (if (is-eq count u0)
            u0
            (/ (* ontime u10000) count)
        )
      )
    u0
  )
)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Notes
;; - Deviations are stored in seconds to maintain precision; consumers can
;;   convert to minutes off-chain.
;; - Aggregation avoids iteration by updating pre-computed counters per route/day.
;; - Threshold-based on-time classification keeps on-chain logic simple and cheap.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
