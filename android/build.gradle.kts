allprojects {
    repositories {
        val useMirrors = providers.environmentVariable("FQAPP_USE_MAVEN_MIRRORS")
            .orNull?.equals("false", ignoreCase = true) != true
        if (useMirrors) {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/central") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
        }
        google()
        mavenCentral()
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
// flutter_qjs links libqjs.so with the NDK defaults, which keep 32-bit ABIs at
// 4 KiB pages; the APK gate requires 16 KiB LOAD alignment on every ABI.
subprojects {
    if (name == "flutter_qjs") {
        pluginManager.withPlugin("com.android.library") {
            extensions.getByName("android").withGroovyBuilder {
                "getDefaultConfig"().withGroovyBuilder {
                    "getExternalNativeBuild"().withGroovyBuilder {
                        "getCmake"().withGroovyBuilder {
                            "arguments"(
                                "-DCMAKE_SHARED_LINKER_FLAGS=" +
                                    "-Wl,-z,max-page-size=16384 -Wl,-z,common-page-size=16384",
                            )
                        }
                    }
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
