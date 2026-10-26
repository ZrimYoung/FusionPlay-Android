import Foundation

@main struct VolumeSmoke {
    static func main() {
        var volume = VolumeInteraction()
        volume.observe(50)
        volume.beginEditing()
        volume.edit(83.4)
        for _ in 0..<10 { volume.observe(50) }
        precondition(volume.value == 83.4, "Diagnostics must not move the thumb during a drag")
        let first = volume.submit()
        precondition(first.value == 83)
        volume.observe(50)
        volume.complete(first.token, succeeded: true)
        volume.observe(50)
        precondition(volume.value == 83, "Queued feedback must not override an unacknowledged commit")
        volume.observe(83)
        volume.observe(27)
        precondition(volume.value == 27, "Phone volume changes must resume after acknowledgement")

        volume.beginEditing(); volume.edit(60)
        let older = volume.submit()
        volume.beginEditing(); volume.edit(70)
        volume.complete(older.token, succeeded: true)
        volume.observe(60)
        precondition(volume.value == 70, "An earlier completion must not overwrite a new gesture")
        let newer = volume.submit()
        precondition(!volume.complete(older.token, succeeded: false))
        volume.observe(70) // acknowledgement may precede command completion
        volume.complete(newer.token, succeeded: true)
        volume.observe(42)
        precondition(volume.value == 42)

        volume.beginEditing(); volume.edit(95)
        let failed = volume.submit()
        volume.observe(35)
        volume.complete(failed.token, succeeded: false)
        precondition(volume.value == 35, "Failed commits restore the last receiver volume")

        volume.beginEditing(); volume.edit(90)
        let lost = volume.submit()
        volume.complete(lost.token, succeeded: true)
        volume.beginEditing(); volume.edit(65)
        volume.expire(lost.token)
        precondition(volume.value == 65, "Timeout must not overwrite a newer drag")
        let same = volume.submit()
        volume.observe(65); volume.complete(same.token, succeeded: true)
        volume.observe(20)
        precondition(volume.value == 20)
        print("Volume drag, queued feedback, acknowledgement ordering, overlap, failure and timeout: PASS")
    }
}
