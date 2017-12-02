//
//  main.m
//  ZombieDetector
//
//  Created by apple on 2017/11/28.
//  Copyright © 2017年 apple. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import <objc/runtime.h>
#include <pthread.h>
#import "fishhook.h"

const size_t MAX_RETAINED_MEM_SIZE  = 100*1024*1024;    // 保留的内存大小上限
const size_t MAX_RETAINED_MEM_COUNT = 1024*1024*10;     // 保留的内存指针（对象）上限
const int BATCH_FREE_MEM_COUNT = 100;                   // 一次批量释放的内存指针数量

/**
 * 保留内存队列节点
 * @field ptr: 内存指针
 * @field size: 内存区域所占字节数
 * @field prev: 前节点指针
 * @field next: 后节点指针
 */
struct mem_node {
    void *ptr;
    size_t size;
    struct mem_node *prev;
    struct mem_node *next;
};

/**
 * 保留内存队列
 * @field header: 队列头指针
 * @field tail: 队列尾指针
 * @field count: 队列node计数
 * @field size: 队列已保留的内存大小
 */
struct mem_queue {
    struct mem_node *header;
    struct mem_node *tail;
    
    int count;
    size_t size;
};

static struct mem_queue retained_mem_queue;    // 保留内存队列
pthread_mutex_t retained_mem_queue_mutex;      // 保留内存队列同步对象

extern size_t malloc_size(const void *ptr);     // 声明malloc_size接口
static void (*origin_free)(void *);             // 保存系统原始的free接口指针

/**
 * 从保留队列中批量释放掉一部分对象（内存空间）
 * @param number 释放的对象数量
 */
void free_some_mem(int number) {
    if (!retained_mem_queue.count || number <= 0) {
        return;
    }
    
    struct mem_node *p = retained_mem_queue.tail;
    for (int i = 0; p && i < number && retained_mem_queue.count > 0; ++i) {
        struct mem_node *pp = p->prev;
        
        // 断链p
        retained_mem_queue.tail = pp;
        if (pp != NULL) {
            pp->next = NULL;
        }
        
        // 更新队列
        retained_mem_queue.count--;
        retained_mem_queue.size -= p->size;
        
        if (!pp) {
            retained_mem_queue.header =
            retained_mem_queue.tail = NULL;
            
            retained_mem_queue.count = 0;
            retained_mem_queue.size = 0;
        }
        
        // 真正释放p所指的内存区域
        origin_free(p->ptr);
        origin_free(p);
        
        p = pp;
    }
}

/**
 * 把ptr指向的内存区域放入保存队列
 * @param ptr 要释放的内存指针。
 */
void retain_mem(void *ptr) {
    if (!ptr) {
        return;
    }
    
    /**
     * [重点] 因为我们接管了free接口，虽然对象在上层已经释放掉了，但是底层还未真正地释放它，
     * 如果用户再向该对象发送消息，该对象还是可以正确响应的，为了避免这种情况，
     * 我们在该片内存区域填充一些无效数据以确保向该僵尸对象发消息时一定会产生Crash。
     */
    size_t size = malloc_size(ptr); // 计算内存区域大小
    memset(ptr, 0x55, size);
    
    /**
     * 正常的队双向列插入（追加）操作
     */
    struct mem_node *node = malloc(sizeof(struct mem_node));
    node->ptr = ptr;
    node->size = size;
    node->prev = NULL;
    node->next = NULL;
    
    if (retained_mem_queue.header == NULL) {
        retained_mem_queue.header = node;
    }
    
    if (retained_mem_queue.tail == NULL) {
        retained_mem_queue.tail = node;
    } else {
        node->prev = retained_mem_queue.tail;
        retained_mem_queue.tail->next = node;
        retained_mem_queue.tail = node;
    }
    
    // 更新队列的统计信息：count和size字段
    retained_mem_queue.count++;
    retained_mem_queue.size += size;
}

/**
 * 判断ptr是否是一个OC对象。
 * @param ptr 要释放的内存指针。
 * @return 1表示ptr所指的对象是一个OC对象，反之不是一个OC对象。
 */
int is_ptr_an_oc_object(void *ptr) {
    // TODO: 还未实现，可以尝试自己动手。
    return 1;
}

/**
 * 我们自己的free接口, 要保证该接口是线程安全的。
 * @param ptr 要释放的内存指针。
 */
void my_free(void *ptr) {
    if (!ptr) {
        return;
    }
    
    // 我们可以优化下跟踪范围：
    // 只跟踪OC对象，滤掉C、C++对象。
    if (!is_ptr_an_oc_object(ptr)) {
        origin_free(ptr);
        return;
    }
    
    pthread_mutex_lock(&retained_mem_queue_mutex);     // 进入临界区
    if (retained_mem_queue.count > MAX_RETAINED_MEM_COUNT) {   // 跟踪的对象数量超限
        free_some_mem(BATCH_FREE_MEM_COUNT);         // 批量释放掉一部分以便为后来者腾出空间
        retain_mem(ptr);                             // 把ptr放入保留队列
    } else {
        size_t size = malloc_size(ptr);                 // 计算ptr所指内存区域的大小
        if (retained_mem_queue.size + size > MAX_RETAINED_MEM_SIZE) {  // 跟踪的对象所占内存大小总和超限
            free_some_mem(BATCH_FREE_MEM_COUNT);     // 批量释放掉一部分以便为后来者腾出空间
            retain_mem(ptr);                         // 把ptr放入保留队列
        } else {                                        // {队列count和size都未超限}
            retain_mem(ptr);                         // 把ptr放入保留队列
        }
    }
    pthread_mutex_unlock(&retained_mem_queue_mutex);   // 离开临界区
}


int main(int argc, char * argv[]) {
    @autoreleasepool {
        // 初始化内存保留队列
        memset(&retained_mem_queue, 0x0, sizeof(retained_mem_queue));
        
        // 初始化队列同步对象(处于效率考虑采用 pthread_mutex_t)
        pthread_mutex_init(&retained_mem_queue_mutex, NULL);
        
        // hook C的free接口（更通用、更底层）
        // 这里有很多接口可供参考，例如：OC runtime的object_dispose。
        struct rebinding rb =
        {"free", my_free, (void *)&origin_free};
        rebind_symbols(&rb, 1);
        
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
