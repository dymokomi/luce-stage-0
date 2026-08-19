; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/workers.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/workers.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [16 x i8] c"integer overflow"
@luce.text.1 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.2 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.3 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.4 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.5 = private unnamed_addr constant [6 x i8] c"square"
@luce.text.6 = private unnamed_addr constant [58 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/workers.luc"
@luce.origins.0 = private constant [4 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }]
@luce.text.7 = private unnamed_addr constant [4 x i8] c"main"
@luce.origins.1 = private constant [17 x { i32, i32 }] [{ i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 5, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }, { i32, i32 } { i32 6, i32 5 }]
@luce.functions = private constant [2 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.5, i64 6, ptr @luce.text.6, i64 58, ptr @luce.origins.0, i64 4 }, { ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.7, i64 4, ptr @luce.text.6, i64 58, ptr @luce.origins.1, i64 17 }]
@luce.text.8 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.square(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3, ptr align 8 nocapture nonnull dereferenceable(8) writeonly noundef %4) {
5:
  %6 = alloca i64, align 8
  store i64 %3, ptr %6, align 8
  br label %7

7:
  %8 = load i64, ptr %6, align 8
  %9 = load i64, ptr %6, align 8
  %10 = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 %8, i64 %9)
  %11 = extractvalue { i64, i1 } %10, 0
  %12 = extractvalue { i64, i1 } %10, 1
  br i1 %12, label %13, label %16, !prof !0

13:
  %14 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 16 }, 0
  %15 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %14, i64 %15)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

16:
  store i64 %11, ptr %4, align 8
  ret i32 0
}

define internal i32 @luce.1.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca i64, align 8
  %7 = alloca i64, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  store i64 4294967295, ptr %6, align 8
  store i64 4294967295, ptr %7, align 8
  %9 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 0
  store i8 4, ptr %9, align 1
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  store i8 -1, ptr %10, align 1
  %11 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 0 }, 0
  %12 = ptrtoint ptr %11 to i64
  %13 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  store i64 %12, ptr %13, align 8
  %14 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 0 }, 1
  %15 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  store i64 %14, ptr %15, align 8
  %16 = alloca { i8, i8, [6 x i8], i64, i64 },i64 1, align 8
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %16, i64 0
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 0
  store i8 2, ptr %18, align 1
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 4
  store i64 0, ptr %19, align 8
  %20 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %21 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %22 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 0
  store i8 6, ptr %23, align 1
  %24 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 4
  store i64 0, ptr %24, align 8
  %25 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %26 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 0
  store i8 2, ptr %26, align 1
  %27 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 4
  store i64 0, ptr %27, align 8
  %28 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %29 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %30 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %31 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 0
  store i8 6, ptr %31, align 1
  %32 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 4
  store i64 0, ptr %32, align 8
  br label %33

33:
  %34 = load i64, ptr %5, align 8
  %35 = trunc i64 %34 to i32
  %36 = lshr i64 %34, 32
  %37 = trunc i64 %36 to i32
  %38 = icmp eq i32 %35, -1
  br i1 %38, label %39, label %42, !prof !0

39:
  %40 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 0
  %41 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %40, i64 %41)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

42:
  %43 = getelementptr inbounds i8, ptr %1, i64 96
  %44 = load ptr, ptr %43, align 8!alias.scope !1, !noalias !2
  %45 = zext i32 %35 to i64
  %46 = mul nsw i64 %45, 112
  %47 = getelementptr inbounds i8, ptr %44, i64 %46
  %48 = getelementptr inbounds i8, ptr %47, i64 96
  %49 = load i32, ptr %48, align 4, !alias.scope !1, !noalias !2
  %50 = icmp ne i32 %49, %37
  br i1 %50, label %51, label %54, !prof !0

51:
  %52 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %53 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %52, i64 %53)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

54:
  %55 = and i32 %49, 1
  %56 = icmp ne i32 %55, 0
  br i1 %56, label %57, label %60, !prof !0

57:
  %58 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 0
  %59 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %58, i64 %59)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 1)
  ret i32 1

60:
  %61 = getelementptr inbounds i8, ptr %47, i64 16
  %62 = load i64, ptr %61, align 8!alias.scope !1, !noalias !2
  %63 = load ptr, ptr %47, align 8, !alias.scope !1, !noalias !2
  %64 = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %62, i64 2)
  %65 = extractvalue { i64, i1 } %64, 0
  %66 = extractvalue { i64, i1 } %64, 1
  br i1 %66, label %67, label %70, !prof !0

67:
  %68 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 16 }, 0
  %69 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 16 }, 1
  call void @luce_rt_raise(ptr %1, i32 0, ptr %68, i64 %69)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 3)
  ret i32 1

70:
  %71 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %17, i32 0, i32 3
  store i64 %65, ptr %71, align 8
  %72 = call i32 @luce_rt_spawn(ptr %1, i64 0, ptr %16, i64 1, ptr %20)
  %73 = icmp ne i32 %72, 0
  br i1 %73, label %74, label %75, !prof !0

74:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 4)
  ret i32 1

75:
  %76 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %20, i32 0, i32 3
  %77 = load i64, ptr %76, align 8
  store i64 %77, ptr %7, align 8
  %78 = load i64, ptr %7, align 8
  %79 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %22, i32 0, i32 3
  store i64 %78, ptr %79, align 8
  %80 = call i32 @luce_rt_task_wait(ptr %1, ptr %22, ptr %21)
  %81 = icmp ne i32 %80, 0
  br i1 %81, label %82, label %83, !prof !0

82:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 7)
  ret i32 1

83:
  %84 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %21, i32 0, i32 3
  %85 = load i64, ptr %84, align 8
  %86 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %25, i32 0, i32 3
  store i64 %85, ptr %86, align 8
  %87 = call i32 @luce_rt_str(ptr %1, ptr %25, ptr %28)
  %88 = icmp ne i32 %87, 0
  br i1 %88, label %89, label %90, !prof !0

89:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 8)
  ret i32 1

90:
  %91 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 3
  %92 = load i64, ptr %91, align 8
  %93 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 1
  %94 = load i8, ptr %93, align 1
  %95 = icmp eq i8 %94, -1
  %96 = inttoptr i64 %92 to ptr
  %97 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 2
  %98 = select i1 %95, ptr %96, ptr %97
  %99 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %28, i32 0, i32 4
  %100 = load i64, ptr %99, align 8
  %101 = zext i8 %94 to i64
  %102 = select i1 %95, i64 %100, i64 %101
  %103 = insertvalue { ptr, i64 } poison, ptr %98, 0
  %104 = insertvalue { ptr, i64 } %103, i64 %102, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %28, i64 24, i1 false)
  %105 = extractvalue { ptr, i64 } %104, 0
  %106 = extractvalue { ptr, i64 } %104, 1
  call void @luce_rt_effects_enter(ptr %1)
  %107 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %108 = load ptr, ptr %107, align 8
  %109 = icmp eq ptr %108, null
  br i1 %109, label %110, label %113, !prof !0

110:
  %111 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %112 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %111, i64 %112)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 10)
  ret i32 1

113:
  %114 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %115 = load ptr, ptr %114, align 8
  %116 = call i32 %108(ptr %115, ptr %105, i64 %106)
  call void @luce_rt_effects_leave(ptr %1)
  %117 = icmp eq i32 %116, -1
  br i1 %117, label %118, label %119, !prof !0

118:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

119:
  %120 = icmp ne i32 %116, 0
  %121 = icmp ne i32 %116, 1
  %122 = and i1 %120, %121
  br i1 %122, label %123, label %126, !prof !0

123:
  %124 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %125 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %124, i64 %125)
  call void @luce_rt_unwound(ptr %1, i32 1, i32 10)
  ret i32 1

126:
  %127 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  %128 = load i64, ptr %127, align 8
  %129 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  %130 = load i8, ptr %129, align 1
  %131 = icmp eq i8 %130, -1
  %132 = inttoptr i64 %128 to ptr
  %133 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 2
  %134 = select i1 %131, ptr %132, ptr %133
  %135 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  %136 = load i64, ptr %135, align 8
  %137 = zext i8 %130 to i64
  %138 = select i1 %131, i64 %136, i64 %137
  %139 = insertvalue { ptr, i64 } poison, ptr %134, 0
  %140 = insertvalue { ptr, i64 } %139, i64 %138, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %8, ptr %29)
  %141 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %29, i32 0, i32 3
  %142 = load i64, ptr %141, align 8
  %143 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %29, i32 0, i32 1
  %144 = load i8, ptr %143, align 1
  %145 = icmp eq i8 %144, -1
  %146 = inttoptr i64 %142 to ptr
  %147 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %29, i32 0, i32 2
  %148 = select i1 %145, ptr %146, ptr %147
  %149 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %29, i32 0, i32 4
  %150 = load i64, ptr %149, align 8
  %151 = zext i8 %144 to i64
  %152 = select i1 %145, i64 %150, i64 %151
  %153 = insertvalue { ptr, i64 } poison, ptr %148, 0
  %154 = insertvalue { ptr, i64 } %153, i64 %152, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %8, ptr align 8 %29, i64 24, i1 false)
  %155 = load i64, ptr %7, align 8
  %156 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %30, i32 0, i32 3
  store i64 %155, ptr %156, align 8
  %157 = call i32 @luce_rt_release(ptr %1, ptr %30)
  %158 = icmp ne i32 %157, 0
  br i1 %158, label %159, label %160, !prof !0

159:
  call void @luce_rt_unwound(ptr %1, i32 1, i32 15)
  ret i32 1

160:
  ret i32 0
}

define internal i32 @luce.worker(ptr %0, ptr %1, i64 %2, ptr %3, i64 %4, ptr %5, i64 %6) {
7:
  %8 = alloca i64, align 8
  switch i64 %2, label %9 [
    i64 0, label %10
  ]

9:
  ret i32 1

10:
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %3, i64 0
  %12 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %11, i32 0, i32 3
  %13 = load i64, ptr %12, align 8
  %14 = call i32 @luce.0.square(ptr %0, ptr %1, i64 %6, i64 %13, ptr %8)
  %15 = icmp eq i32 %14, 0
  br i1 %15, label %16, label %21, !prof !3

16:
  %17 = load i64, ptr %8, align 8
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %5, i32 0, i32 0
  store i8 2, ptr %18, align 1
  %19 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %5, i32 0, i32 4
  store i64 0, ptr %19, align 8
  %20 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %5, i32 0, i32 3
  store i64 %17, ptr %20, align 8
  br label %21

21:
  ret i32 %14
}

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64 %0, i64 %1) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #1

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #1

; Function Attrs: nounwind speculatable willreturn nofree nosync nocallback memory(none)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %0, i64 %1) #0

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_spawn(ptr nocapture nonnull noundef %0, i64 %1, ptr %2, i64 %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #2

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_task_wait(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #2

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #4

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_effects_enter(ptr nocapture nonnull noundef %0) #2

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_effects_leave(ptr nocapture nonnull noundef %0) #5

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #6

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #7

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #2

define i32 @luce_main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0) {
1:
  %2 = alloca i64, align 8
  %3 = alloca i32, align 8
  store i64 256, ptr %2, align 8
  %4 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %5 = load ptr, ptr %4, align 8
  %6 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 14
  %7 = load ptr, ptr %6, align 8
  %8 = icmp eq ptr %7, null
  br i1 %8, label %11, label %9

9:
  %10 = call i64 %7(ptr %5)
  store i64 %10, ptr %2, align 8
  br label %11

11:
  %12 = load i64, ptr %2, align 8
  %13 = call ptr @luce_rt_open(ptr @luce.functions, i64 2)
  %14 = icmp eq ptr %13, null
  br i1 %14, label %15, label %16, !prof !0

15:
  ret i32 2

16:
  %17 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 28
  %18 = load ptr, ptr %17, align 8
  %19 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 54
  %20 = load ptr, ptr %19, align 8
  %21 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 55
  %22 = load ptr, ptr %21, align 8
  %23 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 56
  %24 = load ptr, ptr %23, align 8
  %25 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 57
  %26 = load ptr, ptr %25, align 8
  %27 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 58
  %28 = load ptr, ptr %27, align 8
  %29 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 29
  %30 = load ptr, ptr %29, align 8
  %31 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 30
  %32 = load ptr, ptr %31, align 8
  %33 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 31
  %34 = load ptr, ptr %33, align 8
  %35 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 32
  %36 = load ptr, ptr %35, align 8
  call void @luce_rt_files_install(ptr %13, ptr %5, ptr %18, ptr %20, ptr %22, ptr %24, ptr %26, ptr %28, ptr %30, ptr %32, ptr %34, ptr %36)
  %37 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 48
  %38 = load ptr, ptr %37, align 8
  %39 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 49
  %40 = load ptr, ptr %39, align 8
  %41 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 50
  %42 = load ptr, ptr %41, align 8
  %43 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 51
  %44 = load ptr, ptr %43, align 8
  %45 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 52
  %46 = load ptr, ptr %45, align 8
  call void @luce_rt_sockets_install(ptr %13, ptr %5, ptr %38, ptr %40, ptr %42, ptr %44, ptr %46)
  %47 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 40
  %48 = load ptr, ptr %47, align 8
  %49 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 41
  %50 = load ptr, ptr %49, align 8
  %51 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 42
  %52 = load ptr, ptr %51, align 8
  %53 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 43
  %54 = load ptr, ptr %53, align 8
  %55 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 44
  %56 = load ptr, ptr %55, align 8
  %57 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 45
  %58 = load ptr, ptr %57, align 8
  %59 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 46
  %60 = load ptr, ptr %59, align 8
  %61 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 47
  %62 = load ptr, ptr %61, align 8
  call void @luce_rt_graphics_install(ptr %13, ptr %5, ptr %48, ptr %50, ptr %52, ptr %54, ptr %56, ptr %58, ptr %60, ptr %62)
  %63 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 33
  %64 = load ptr, ptr %63, align 8
  %65 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 34
  %66 = load ptr, ptr %65, align 8
  call void @luce_rt_workers_install(ptr %13, ptr %5, ptr %64, ptr %66, ptr %0, ptr @luce.worker, i64 %12)
  %67 = icmp slt i64 %12, 1
  br i1 %67, label %68, label %69, !prof !0

68:
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.8, i64 19)
  store i32 1, ptr %3, align 8
  br label %77

69:
  %70 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %71 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 4
  %72 = load ptr, ptr %71, align 8
  %73 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 5
  %74 = load ptr, ptr %73, align 8
  %75 = call i32 @luce_rt_args_list(ptr %13, ptr %5, ptr %72, ptr %74, ptr %70)
  %76 = icmp ne i32 %75, 0
  br i1 %76, label %81, label %82, !prof !0

77:
  %78 = load i32, ptr %3, align 8
  %79 = icmp eq i32 %78, 1
  %80 = icmp eq i32 %78, 2
  br i1 %79, label %87, label %90, !prof !0

81:
  store i32 1, ptr %3, align 8
  br label %77

82:
  %83 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %70, i32 0, i32 3
  %84 = load i64, ptr %83, align 8
  %85 = call i32 @luce.1.main(ptr %0, ptr %13, i64 %12, i64 %84)
  store i32 %85, ptr %3, align 8
  %86 = call i32 @luce_rt_release(ptr %13, ptr %70)
  br label %77

87:
  %88 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 2
  %89 = load ptr, ptr %88, align 8
  call void @luce_rt_report(ptr %13, ptr %5, ptr %89)
  br label %90

90:
  br i1 %80, label %91, label %94, !prof !0

91:
  %92 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 15
  %93 = load ptr, ptr %92, align 8
  call void @luce_rt_report_error(ptr %13, ptr %5, ptr %93)
  br label %94

94:
  %95 = call i32 @luce_rt_status(ptr %13, i32 %78)
  %96 = icmp eq i32 %95, 2
  %97 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 3
  %98 = load ptr, ptr %97, align 8
  %99 = icmp eq ptr %98, null
  %100 = or i1 %99, %96
  br i1 %100, label %101, label %102

101:
  call void @luce_rt_close(ptr %13)
  ret i32 %95

102:
  %103 = call i64 @luce_rt_leaked(ptr %13)
  call void %98(ptr %5, i64 %103)
  br label %101
}

; Function Attrs: nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite)
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #8

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #9

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #5

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #9

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_workers_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, i64 %6) #9

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #2

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #10

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #10

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #11

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #11

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #2

attributes #0 = { nounwind speculatable willreturn nofree nosync nocallback memory(none) }
attributes #1 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #2 = { nounwind memory(readwrite) }
attributes #3 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #5 = { nounwind willreturn memory(readwrite) }
attributes #6 = { nounwind cold willreturn memory(argmem: write) }
attributes #7 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #8 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #9 = { nounwind willreturn memory(argmem: readwrite) }
attributes #10 = { cold }
attributes #11 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!4}
!2 = !{!5}
!3 = !{!"branch_weights", i32 2000, i32 1}
!4 = !{!"luce.rows", !6}
!5 = !{!"luce.elements", !6}
!6 = !{!"luce.alias"}
