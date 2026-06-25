allprojects {
    repositories {
        google()
        mavenCentral()
    }
    // Pin a single androidx.work version across ALL modules (incl. the workmanager
    // plugin). The workmanager 0.5.2 plugin pulls work-runtime-ktx:2.7.1 while the
    // newer transitive graph pulls work-runtime:2.8.1 — the mismatch duplicates
    // androidx.work.*Kt classes (CheckDuplicates failure) and breaks the plugin's
    // Kotlin compile. work-runtime-ktx:2.8.1 is a stub (ktx merged into runtime at
    // 2.8), so forcing both to 2.8.1 deduplicates cleanly.
    configurations.all {
        resolutionStrategy {
            force("androidx.work:work-runtime:2.8.1")
            force("androidx.work:work-runtime-ktx:2.8.1")
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
