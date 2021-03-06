//
//  CoredataProvider.swift
//  DatabaseSyncRx
//
//  Created by Lobanov Aleksey on 17/10/2017.
//  Copyright © 2017 Lobanov Aleksey. All rights reserved.
//

import Foundation
import CoreData
import Sync
import RxSwift
import ObjectMapper

///
public protocol CoredataMappable {
  /// Save single entity by source dictionary and type
  ///
  /// - Parameters:
  ///   - type: Type of `NSManagedObjectMappable`, ex. `PetEntity.self`
  ///   - json: Source dictionary `JSONDictionary = [String: Any]`
  /// - Returns: Observable<Void>
  func mapObject<T: NSManagedObjectMappable>(_ type: T.Type, json: JSONDictionary) -> Observable<Void>
  
  /// Save array of entity by source array of dictionary and type
  ///
  /// - Parameters:
  ///   - type: Type of `NSManagedObjectMappable`, ex. `PetEntity.self`
  ///   - json: Source array of dictionary `JSONArrayDictionary = [[String: Any]]`
  /// - Returns: Observable<Void>
  func mapArray<T: NSManagedObjectMappable>(_ type: T.Type, jsonArray: JSONArrayDictionary) -> Observable<Void>
//  func edit(_ closure: @escaping EditOperation.ActionClosure) -> Observable<Void>
}

public protocol CoredataDeletable {
  
  /// Delete `NSManagedObject` object by type and primary key value
  ///
  /// - Parameters:
  ///   - type: Type of `NSManagedObjectMappable`, ex. `PetEntity.self`
  ///   - id: `Any` object, usually type is `Int`
  /// - Returns: Observable<Void>
  func delete<T: NSManagedObject>(_ type: T.Type, id: Any) -> Observable<Void>
  
  /// Delete list of `NSManagedObject` object by type and list of primary keys
  ///
  /// - Parameters:
  ///   - type: Type of `NSManagedObjectMappable`, ex. `PetEntity.self`
  ///   - ids: List of `Any` objects, usually type is `Int`
  /// - Returns: Observable<Void>
  func delete<T: NSManagedObject>(_ type: T.Type, ids: [Any]) -> Observable<Void>
}

public protocol CoredataFetcher {
  func models<T: Mappable, U: NSManagedObject>(type: U.Type, predicate: NSPredicate, sort: [NSSortDescriptor]?) -> [T]?
  func models<T: Mappable, U: NSManagedObject>(type: U.Type, predicate: NSPredicate) -> [T]?
  func relation<T: Mappable, U: NSManagedObject>(from: U.Type, name: String, pk: Any, pkKey: String, sort: [NSSortDescriptor]?) -> [T]?
  func firstModel<T: Mappable, U: NSManagedObject>(type: U.Type, predicate: NSPredicate) -> T?
  
  func objects<T: NSManagedObject>(type: T.Type, predicate: NSPredicate, sort: [NSSortDescriptor]?) -> [T]?
  func firstObject<T: NSManagedObject>(type: T.Type, predicate: NSPredicate) -> T?
  
  func mainContext() -> NSManagedObjectContext
}

public protocol CoredataCleanable {
  func clean(doNotDeleteEntities:[NSManagedObject.Type]) -> Observable<Void>
}

public class CoredataProvider: CoredataMappable, CoredataFetcher, CoredataCleanable, CoredataDeletable {
  
  let dataStack: DataStack
  let serialOperationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    queue.underlyingQueue = DispatchQueue(label: "ru.mops.serialDatabaseQueue")
    queue.waitUntilAllOperationsAreFinished()
    return queue
  }()
  
  public init(dataStack: DataStack) {
    self.dataStack = dataStack
  }
}

public extension CoredataCleanable  where Self: CoredataProvider {
  
  func clean(doNotDeleteEntities:[NSManagedObject.Type]) -> Observable<Void> {
    return Observable<Void>.create({ [weak self] observer -> Disposable in
      
      guard let stack = self?.dataStack else {
        observer.onError(NSError(domain: "ru.lobanov", code: 0, userInfo: nil)) //ORMError.ormWriteError.error)
        return Disposables.create()
      }
      
      var entitiesNames = [String]()
      for entity in stack.persistentStoreCoordinator.managedObjectModel.entities {
        if let name = entity.name,
          let managedObjectClass = NSClassFromString(entity.managedObjectClassName)
        {
          let contains = doNotDeleteEntities.contains(where: { type -> Bool in
            return managedObjectClass.isSubclass(of: type.self) || type.isSubclass(of: managedObjectClass.self) || managedObjectClass.self == type.self
          })
          if (!contains) {
            entitiesNames.append(name)
          }
        }
      }
      
      stack.performInNewBackgroundContext({ context in
        do {
          for name in entitiesNames {
            let deleteAllRequest = NSBatchDeleteRequest(fetchRequest: NSFetchRequest<NSFetchRequestResult>(entityName: name))
            try context.execute(deleteAllRequest)
          }
          observer.onNext(())
          observer.onCompleted()
        } catch let(err) {
          observer.onError(err)
        }
      })
      return Disposables.create()
    }).observeOn(DBSchedulers.shared.mainScheduler)
  }
  
}

public extension CoredataMappable where Self: CoredataProvider {
  func mapObject<T: NSManagedObjectMappable>(_ type: T.Type, json: JSONDictionary) -> Observable<Void> {
    return mapArray(type, jsonArray: [json])
  }
  
  func mapArray<T: NSManagedObjectMappable>(_ type: T.Type, jsonArray: JSONArrayDictionary) -> Observable<Void> {
    return Observable<Void>.create({ [weak self] observer -> Disposable in
      
      guard let stack = self?.dataStack else {
        observer.onError(NSError(domain: "ru.lobanov", code: 0, userInfo: nil)) //ORMError.ormWriteError.error)
        return Disposables.create()
      }
      
      let op = EditOperation(action: { context -> Observable<Void> in
        let mapper = EntityMapper<T>(context: context, objects: jsonArray)
        let result: Observable<[T]> = mapper.mapArray(type: T.self) //T.mapArray(jsonArray, type: T.self, context: context)
        return result.mapToVoid()
      }, dataStack: stack)
      
      op.completion = { error in
        if let existErr = error {
          observer.onError(existErr)
        } else {
          observer.onNext(())
          observer.onCompleted()
        }
      }
      
      self?.serialOperationQueue.addOperation(op)
      return Disposables.create()
    }).observeOn(DBSchedulers.shared.mainScheduler)
  }
  
//  func edit(_ closure: @escaping EditOperation.ActionClosure) -> Observable<Void> {
//    return Observable<Void>.create({ [weak self] observer -> Disposable in
//
//      guard let stack = self?.dataStack else {
//        observer.onError(NSError(domain: "ru.lobanov", code: 0, userInfo: nil)) //ORMError.ormWriteError.error)
//        return Disposables.create()
//      }
//
//      let op = EditOperation(action: closure, dataStack: stack)
//      op.completion = { error in
//        if let existErr = error {
//          observer.onError(existErr)
//        } else {
//          observer.onNext(())
//          observer.onCompleted()
//        }
//      }
//      self?.serialOperationQueue.addOperation(op)
//      return Disposables.create()
//    }).observeOn(Schedulers.shared.mainScheduler)
//  }
  
}

public extension CoredataFetcher where Self: CoredataProvider {
  
  func mainContext() -> NSManagedObjectContext {
    return dataStack.mainContext
  }
  
  func relation<T: Mappable, U: NSManagedObject>(from: U.Type, name: String, pk: Any, pkKey: String, sort: [NSSortDescriptor]?) -> [T]? {
    let relationPred = NSPredicate(format: "SUBQUERY(\(name), $m, ANY $m.\(pkKey) IN %@).@count > 0", [pk])
    return self.models(type: U.self, predicate: relationPred, sort: sort)
  }
  
  func models<T: Mappable, U: NSManagedObject>(type: U.Type, predicate: NSPredicate) -> [T]? {
    return self.models(type: type, predicate: predicate, sort: nil)
  }
  
  func models<T: Mappable, U: NSManagedObject>(type: U.Type, predicate: NSPredicate, sort: [NSSortDescriptor]?) -> [T]? {
    do {
      let entityName = String(describing: type.self)
      let fetchRequest : NSFetchRequest<U> = NSFetchRequest(entityName: entityName)
      fetchRequest.predicate = predicate
      
      if let descriptors = sort {
        fetchRequest.sortDescriptors = descriptors
      }
      
      let fetchedResults = try dataStack.mainContext.fetch(fetchRequest)
      
      return fetchedResults.flatMap { model -> T? in
        let json = model.export()
        if let obj: T = Mapper<T>().map(JSON: json) {
          return obj
        } else {
          return nil
        }
      }
    } catch {
      return nil
    }
  }
  
  func firstModel<T: Mappable, U: NSManagedObject>(type: U.Type, predicate: NSPredicate) -> T? {
    do {
      let entityName = String(describing: type.self)
      let fetchRequest : NSFetchRequest<U> = NSFetchRequest(entityName: entityName)
      
      fetchRequest.predicate = predicate
      let fetchedResults = try self.dataStack.mainContext.fetch(fetchRequest)
      
      return fetchedResults.flatMap { model -> T? in
        let json = model.export()
        if let obj: T = Mapper<T>().map(JSON: json) {
          return obj
        } else {
          return nil
        }
        }.first
    } catch {
      return nil
    }
  }
  
  func objects<T: NSManagedObject>(type: T.Type, predicate: NSPredicate, sort: [NSSortDescriptor]?) -> [T]? {
    do {
      let entityName = String(describing: type.self)
      let fetchRequest : NSFetchRequest<T> = NSFetchRequest(entityName: entityName)
      fetchRequest.predicate = predicate
      
      if let descriptors = sort {
        fetchRequest.sortDescriptors = descriptors
      }
      
      return try self.dataStack.mainContext.fetch(fetchRequest)
    } catch {
      return nil
    }
  }
  
  func firstObject<T: NSManagedObject>(type: T.Type, predicate: NSPredicate) -> T? {
    do {
      let entityName = String(describing: type.self)
      let fetchRequest : NSFetchRequest<T> = NSFetchRequest(entityName: entityName)
      fetchRequest.predicate = predicate
      
      return try self.dataStack.mainContext.fetch(fetchRequest).first
    } catch {
      return nil
    }
  }
}

public extension CoredataDeletable where Self: CoredataProvider {
  
  func delete<T: NSManagedObject>(_ type: T.Type, id: Any) -> Observable<Void> {
    return delete(type, ids: [id])
  }
  
  func delete<T: NSManagedObject>(_ type: T.Type, ids: [Any]) -> Observable<Void> {
    return Observable<Void>.create({ [weak self] observer -> Disposable in
      
      guard let stack = self?.dataStack else {
        observer.onError(NSError.define(description: "Data stack is undefined"))
        return Disposables.create()
      }
      
      let op = DeleteArrayOperation<T>(ids: ids, dataStack: stack)
      op.completion = { error in
        if let existErr = error {
          observer.onError(existErr)
        } else {
          observer.onNext(())
          observer.onCompleted()
        }
      }
      
      self?.serialOperationQueue.addOperation(op)
      return Disposables.create()
    }).observeOn(DBSchedulers.shared.mainScheduler)
  }
  
}
